import AppKit
import MetalKit
import QuartzCore
import IOKit

/// Drives the whole effect: input (lid angle / debug slider / fallback animation) -> smoothed progress
/// -> screen capture -> blur pyramid -> full-screen overlay on the built-in display.
@MainActor
final class EffectEngine: NSObject, ObservableObject, MTKViewDelegate {
    enum InputMode: String, CaseIterable, Identifiable {
        case sensor   // follow the lid angle
        case manual   // debug slider
        var id: String { rawValue }
    }

    @Published var params: EffectParams = .load() {
        didSet {
            guard params != oldValue else { return }
            params.save()
            if params.filter != oldValue.filter { forcePyramid = true }
            evaluate()
        }
    }
    @Published var inputMode: InputMode { didSet { evaluate() } }
    @Published var manualProgress: Double = 1 { didSet { evaluate() } }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); evaluate() }
    }
    @Published var fallbackOnWake: Bool = UserDefaults.standard.object(forKey: "fallbackOnWake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fallbackOnWake, forKey: "fallbackOnWake") }
    }
    @Published private(set) var uiAngle: Double?
    @Published private(set) var uiProgress: Double = 1
    @Published private(set) var sensorStatus: String = ""
    @Published private(set) var captureStatus: String = "대기"
    @Published private(set) var overlayVisible = false
    @Published private(set) var screenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var builtInPresent = Displays.builtInScreen != nil

    let sensor = LidAngleSensor()
    private var renderer: EffectRenderer?
    private var textureCache: PixelBufferTextureCache?
    private let capturer = ScreenCapturer()
    private var window: NSWindow?
    private var mtkView: MTKView?
    private var displayLink: CADisplayLink?
    private var idleTimer: Timer?
    private var smoothed: Double = 1
    private var lastTick: CFTimeInterval = 0
    private var lastSeq: UInt64 = 0
    private var forcePyramid = false
    private var settledSince: CFTimeInterval?
    private var farSince: CFTimeInterval?
    private var snapUntil: CFTimeInterval = 0       // fallback animation uses lerpSnap until then
    private var captureStarting = false
    private var lastUIUpdate: CFTimeInterval = 0
    private var clamshellClosedAtSleep = false
    private var observers: [NSObjectProtocol] = []

    /// Degrees above `openAngle` at which capture is pre-started so the first frame is ready.
    private let prewarmDegrees = 10.0
    private let eps = 0.0005

    init(defaultMode: InputMode) {
        let saved = UserDefaults.standard.string(forKey: "inputMode").flatMap(InputMode.init(rawValue:))
        inputMode = saved ?? defaultMode
        super.init()
        renderer = try? EffectRenderer()
        if let r = renderer { textureCache = PixelBufferTextureCache(device: r.device) }
        sensorStatus = sensor.statusText
        NSLog("LidBlur: sensor %@ angle %@", sensor.statusText, sensor.angle.map { String($0) } ?? "nil")
        capturer.onError = { [weak self] err in
            Task { @MainActor in self?.captureStatus = "캡처 중단: \(err.localizedDescription)" }
        }
        installObservers()
        sensor.setPollingRate(sensor.isAvailable ? 20 : 0)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.idleTick() }
        }
        evaluate()
    }

    func persistMode() { UserDefaults.standard.set(inputMode.rawValue, forKey: "inputMode") }

    // MARK: Input

    private var target: Double {
        guard enabled, builtInPresent else { return 1 }
        switch inputMode {
        case .manual: return manualProgress
        case .sensor:
            if let a = sensor.angle { return params.progress(forAngle: a) }
            return 1
        }
    }

    /// Plays the opening animation used when no lid-angle sensor is available (closed -> open).
    func playOpenAnimation() {
        smoothed = 0
        snapUntil = CACurrentMediaTime() + 4
        activate()
    }

    func requestScreenPermission() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        screenPermission = CGPreflightScreenCaptureAccess()
    }

    // MARK: State machine

    private func idleTick() {
        screenPermission = CGPreflightScreenCaptureAccess()
        if displayLink == nil { evaluate(); updateUI(force: false) }
    }

    func evaluate() {
        let t = target
        let near: Bool = {
            guard enabled, builtInPresent, inputMode == .sensor, let a = sensor.angle else { return false }
            return a < params.openAngle + prewarmDegrees
        }()
        let needsEffect = t < 1 - eps || smoothed < 1 - eps
        if needsEffect || near {
            farSince = nil
            ensureCapture()
        } else if capturer.isRunning {
            let now = CACurrentMediaTime()
            if farSince == nil { farSince = now }
            if now - (farSince ?? now) > 3 { stopCapture() }
        }
        if needsEffect { activate() }
        sensor.setPollingRate(sensor.isAvailable ? ((near || needsEffect) ? 120 : 20) : 0)
    }

    private func activate() {
        guard builtInPresent, renderer != nil else { return }
        ensureWindow()
        if let w = window, !w.isVisible { w.alphaValue = 0; w.orderFrontRegardless() }
        if displayLink == nil, let screen = Displays.builtInScreen {
            let link = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = CACurrentMediaTime()
        }
    }

    private func deactivate() {
        displayLink?.invalidate()
        displayLink = nil
        window?.alphaValue = 0
        window?.orderOut(nil)
        overlayVisible = false
        settledSince = nil
        updateUI(force: true)
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        let t = target
        let factor = now < snapUntil ? params.lerpSnap : params.lerpDrag
        smoothed = frameLerp(smoothed, t, factor60: factor, dt: dt)
        if abs(smoothed - t) < eps { smoothed = t }

        mtkView?.draw()

        // Show the overlay only once it can show real content (or when it is nearly black anyway).
        if let w = window {
            let canShow = (renderer?.hasSource ?? false) || smoothed < 0.2
            let shouldShow = smoothed < 1 - eps && canShow
            if shouldShow && w.alphaValue < 1 {
                w.orderFrontRegardless()
                w.alphaValue = 1
                overlayVisible = true
            } else if !shouldShow && w.alphaValue > 0 && smoothed >= 1 - eps {
                w.alphaValue = 0
                overlayVisible = false
            }
        }

        if smoothed >= 1 - eps && t >= 1 - eps {
            if settledSince == nil { settledSince = now }
            if now - (settledSince ?? now) > 0.25 { deactivate() }
        } else {
            settledSince = nil
        }
        evaluate()
        updateUI(force: false)
    }

    private func updateUI(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastUIUpdate > 1.0 / 15.0 else { return }
        lastUIUpdate = now
        uiAngle = sensor.angle
        uiProgress = smoothed
        sensorStatus = sensor.statusText
    }

    // MARK: Capture

    private func ensureCapture() {
        guard !capturer.isRunning, !captureStarting, let screen = Displays.builtInScreen, let id = screen.displayID else { return }
        guard CGPreflightScreenCaptureAccess() else { captureStatus = "화면 기록 권한 필요"; return }
        captureStarting = true
        captureStatus = "캡처 시작 중"
        let (w, h) = screen.pixelSize
        Task {
            do {
                try await capturer.start(displayID: id, pixelWidth: w, pixelHeight: h)
                captureStatus = "캡처 중 (\(w)×\(h))"
            } catch {
                captureStatus = "캡처 실패: \(error.localizedDescription)"
            }
            captureStarting = false
        }
    }

    private func stopCapture() {
        Task { await capturer.stop() }
        captureStatus = "대기"
        farSince = nil
    }

    // MARK: Overlay window

    private func ensureWindow() {
        guard let screen = Displays.builtInScreen, let renderer else { return }
        if let w = window {
            if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
            return
        }
        let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.animationBehavior = .none
        w.sharingType = .none   // never feed our own output back into a capture
        let v = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: renderer.device)
        v.colorPixelFormat = renderer.colorPixelFormat
        v.framebufferOnly = true
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        v.autoResizeDrawable = true
        v.delegate = self
        v.autoresizingMask = [.width, .height]
        if let layer = v.layer as? CAMetalLayer {
            layer.isOpaque = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.displaySyncEnabled = true
        }
        w.contentView = v
        window = w
        mtkView = v
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { self.render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let renderer, let cache = textureCache,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = renderer.queue.makeCommandBuffer() else { return }
        if let (pb, seq) = capturer.frame(newerThan: forcePyramid ? 0 : lastSeq), let (tex, cvTex) = cache.texture(for: pb) {
            renderer.encodePyramid(from: tex, filter: params.filter, into: cb)
            lastSeq = seq
            forcePyramid = false
            cb.addCompletedHandler { _ in _ = cvTex }
        }
        pass.colorAttachments[0].loadAction = .dontCare
        renderer.encodeEffect(params: params, progress: smoothed, pass: pass, into: cb)
        cb.present(drawable)
        cb.commit()
    }

    // MARK: System events

    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    private func willSleep() {
        clamshellClosedAtSleep = Clamshell.isClosed
        stopCapture()
    }

    private func didWake() {
        if !sensor.isAvailable { _ = sensor.openDevice() }
        sensorStatus = sensor.statusText
        if inputMode == .sensor, sensor.isAvailable, let a = sensor.readOnce() {
            // Start from the current lid position instead of easing from a stale value.
            smoothed = params.progress(forAngle: a)
            if smoothed < 1 - eps { activate() }
        } else if fallbackOnWake && enabled && (clamshellClosedAtSleep || !sensor.isAvailable) {
            playOpenAnimation()
        }
        clamshellClosedAtSleep = false
        evaluate()
    }

    private func screensChanged() {
        builtInPresent = Displays.builtInScreen != nil
        if !builtInPresent {
            deactivate()
            window?.close(); window = nil; mtkView = nil
            stopCapture()
        } else if let screen = Displays.builtInScreen, let w = window, w.frame != screen.frame {
            w.setFrame(screen.frame, display: false)
            stopCapture()
            renderer?.invalidateSource()
        }
        evaluate()
    }
}

/// A window that never takes focus.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum Clamshell {
    /// Whether the lid is currently closed (IOPMrootDomain "AppleClamshellState").
    static var isClosed: Bool {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }
}
