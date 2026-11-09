import AppKit
import MetalKit
import QuartzCore
import IOKit
import ImageIO

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
            if params.effectiveFilter != oldValue.effectiveFilter { forcePyramid = true }
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
    /// Debug: simulated lid angle (not published, so it costs what the real sensor path costs).
    var debugAngle: Double?

    /// Fast-changing state lives in its own object so big views (tuning panel, app scene) do not
    /// re-render on every progress tick.
    let status = LiveStatus()
    /// Only the overlay visibility, for the menu bar icon (re-rendering a status item is costly).
    let iconState = IconState()
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
    private var startToken: Int?            // non-nil while a capture start is in flight
    private var nextStartToken = 0
    private var captureStarting: Bool { startToken != nil }
    private var lastUIUpdate: CFTimeInterval = 0
    private var clamshellClosedAtSleep = false
    private var systemAsleep = false
    private var screenLocked = false
    private var captureGeneration = 0
    private var captureStartAt: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var lastDrawnProgress: Double = -1
    private var lastDrawnParams: EffectParams?
    private var sourceHolder: AnyObject?      // keeps the captured surface (level 0) alive

    /// Degrees above `openAngle` at which capture is pre-started so the first frame is ready.
    private let prewarmDegrees = 20.0
    private let eps = 0.0005

    init(defaultMode: InputMode) {
        let saved = UserDefaults.standard.string(forKey: "inputMode").flatMap(InputMode.init(rawValue:))
        inputMode = saved ?? defaultMode
        super.init()
        renderer = try? EffectRenderer()
        if let r = renderer { textureCache = PixelBufferTextureCache(device: r.device) }
        status.sensorStatus = sensor.statusText
        NSLog("LidBlur: sensor %@ angle %@", sensor.statusText, sensor.angle.map { String($0) } ?? "nil")
        capturer.onError = { [weak self] err in
            Task { @MainActor in self?.status.captureStatus = "캡처 중단: \(err.localizedDescription)" }
        }
        installObservers()
        #if DEBUG
        DebugHooks.current = self
        #endif
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        // Idle is event driven: the sensor wakes us only when the angle changes.
        sensor.onChange = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sensorChanged() } }
        }
        sensor.setPollingRate(sensor.isAvailable ? 5 : 0)
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
        evaluate()
    }

    func persistMode() { UserDefaults.standard.set(inputMode.rawValue, forKey: "inputMode") }

    // MARK: Input

    private var target: Double {
        guard enabled, builtInPresent, !screenLocked else { return 1 }
        switch inputMode {
        case .manual: return manualProgress
        case .sensor:
            if let a = debugAngle ?? sensor.smoothAngle() { return params.progress(forAngle: a) }
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
        let perm = CGPreflightScreenCaptureAccess()
        if perm != screenPermission { screenPermission = perm }
        if displayLink == nil { evaluate(); updateUI(force: false) }
    }

    private func sensorChanged() {
        guard displayLink == nil else { return }   // while active the display link polls every frame
        evaluate()
        updateUI(force: false)
    }

    func evaluate() {
        let t = target
        let near: Bool = {
            guard enabled, builtInPresent, inputMode == .sensor, let a = debugAngle ?? sensor.angle else { return false }
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
        sensor.setPollingRate(sensor.isAvailable ? ((near || needsEffect) ? 20 : 5) : 0)
        // While closing (capture/near), keep the app from being napped so timers stay on time.
        setLatencyCritical(near || needsEffect)
    }

    private var activity: NSObjectProtocol?
    private func setLatencyCritical(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Lid fold effect")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }
    }

    private func activate() {
        guard builtInPresent, renderer != nil else { return }
        ensureWindow()
        if let w = window, !w.isVisible { w.alphaValue = 0; w.orderFrontRegardless() }
        if displayLink == nil, let screen = Displays.builtInScreen {
            let link = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
            let fps = Float(params.maxFrameRate)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, fps), maximum: fps, preferred: fps)
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = CACurrentMediaTime()
        }
    }

    private func deactivate() {
        EventLog.shared.log("deactivate", sensor.angle)
        displayLink?.invalidate()
        displayLink = nil
        window?.alphaValue = 0
        window?.orderOut(nil)
        status.overlayVisible = false; if iconState.active { iconState.active = false }
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

        // Draw only when something visible changed (new captured frame, progress, parameters).
        let seq = capturer.latestSequence
        if seq != lastSeq || abs(smoothed - lastDrawnProgress) > 1e-6 || params != lastDrawnParams || forcePyramid || window?.alphaValue == 0 {
            mtkView?.draw()
            lastDrawnProgress = smoothed
            lastDrawnParams = params
        }

        // Show the overlay only once it can show real content (or when it is nearly black anyway).
        if let w = window {
            let canShow = (renderer?.hasSource ?? false) || smoothed < 0.2
            let shouldShow = smoothed < 1 - eps && canShow
            if shouldShow && w.alphaValue < 1 {
                w.orderFrontRegardless()
                w.alphaValue = 1
                status.overlayVisible = true; if !iconState.active { iconState.active = true }
            } else if !shouldShow && w.alphaValue > 0 && smoothed >= 1 - eps {
                w.alphaValue = 0
                status.overlayVisible = false; if iconState.active { iconState.active = false }
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
        let a = sensor.angle
        if a != status.angle { status.angle = a }
        if abs(status.progress - smoothed) > 0.001 || (force && status.progress != smoothed) { status.progress = smoothed }
        if status.sensorStatus != sensor.statusText { status.sensorStatus = sensor.statusText }
    }

    // MARK: Capture

    private func ensureCapture() {
        if captureStarting, CACurrentMediaTime() - captureStartAt > 4 {
            // A start that never returned (e.g. requested around sleep/lock): abandon it and retry.
            EventLog.shared.log("captureStartTimeout")
            captureGeneration += 1
            startToken = nil
        }
        guard !systemAsleep, !screenLocked, !capturer.isRunning, !captureStarting, let screen = Displays.builtInScreen, let id = screen.displayID else { return }
        guard CGPreflightScreenCaptureAccess() else { status.captureStatus = "화면 기록 권한 필요"; return }
        nextStartToken += 1
        let token = nextStartToken
        startToken = token
        captureStartAt = CACurrentMediaTime()
        status.captureStatus = "캡처 시작 중"
        let (w, h) = screen.pixelSize
        let gen = captureGeneration
        Task {
            do {
                try await capturer.start(displayID: id, pixelWidth: w, pixelHeight: h)
                if gen != captureGeneration || systemAsleep {   // a restart was requested meanwhile
                    await capturer.stop()
                    if startToken == token { startToken = nil }
                    return
                }
                EventLog.shared.log("captureStarted", sensor.angle)
                status.captureStatus = "캡처 중 (\(w)×\(h))"
            } catch {
                status.captureStatus = "캡처 실패: \(error.localizedDescription)"
            }
            if startToken == token { startToken = nil }
        }
    }

    private func stopCapture() {
        captureGeneration += 1
        Task { await capturer.stop() }
        status.captureStatus = "대기"
        farSince = nil
    }

    /// Full restart of the capture path: new stream, no stale frames.
    private func restartCapture() {
        stopCapture()
        renderer?.invalidateSource()
        lastSeq = 0
        sourceHolder = nil
    }

    // MARK: Overlay window

    private func ensureWindow() {
        guard let screen = Displays.builtInScreen, let renderer else { return }
        if let w = window {
            if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
            return
        }
        let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver   // the lock screen is protected by macOS; the effect never draws over it
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.animationBehavior = .none
        // Never feed our own output back into a capture (debug builds can allow it for screenshots).
        w.sharingType = UserDefaults.standard.bool(forKey: "debugAllowOverlayCapture") ? .readOnly : .none
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
            if !renderer.hasSource { EventLog.shared.log("firstFrame", smoothed) }
            renderer.encodePyramid(from: tex, filter: params.effectiveFilter, into: cb)
            lastSeq = seq
            forcePyramid = false
            // The captured surface is level 0 now: keep it alive until it is replaced, and keep the
            // previous one alive until the GPU has finished with it.
            let previous = sourceHolder
            sourceHolder = [pb, cvTex] as NSArray
            cb.addCompletedHandler { _ in _ = previous }
        }
        pass.colorAttachments[0].loadAction = .dontCare
        renderer.encodeEffect(params: params, progress: smoothed, pass: pass, into: cb)
        cb.present(drawable)
        cb.commit()
    }

    // MARK: Debug

    /// Renders what the overlay currently shows into a PNG and returns a status line (testing aid).
    func debugSnapshot(to path: String) -> String {
        var status = "progress=\(smoothed) target=\(target) overlayVisible=\(status.overlayVisible) alpha=\(window?.alphaValue ?? -1) capture=\(status.captureStatus) hasSource=\(renderer?.hasSource ?? false) angle=\(sensor.angle.map { String($0) } ?? "nil")"
        guard let renderer, let pyr = renderer.pyramid else { return status + " (no pyramid)" }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pyr.width, height: pyr.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let out = renderer.device.makeTexture(descriptor: d), let cb = renderer.queue.makeCommandBuffer() else { return status }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        renderer.encodeEffect(params: params, progress: smoothed, pass: pass, into: cb)
        cb.commit(); cb.waitUntilCompleted()
        if let img = ImageOps.cgImage(from: out), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
            status += " wrote \(path) \(out.width)x\(out.height)"
        }
        return status
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
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                EventLog.shared.log("screensDidSleep", self?.sensor.readOnce())
                self?.systemAsleep = true
                self?.restartCapture()
            }
        })
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                EventLog.shared.log("locked")
                self?.screenLocked = true
                self?.restartCapture()
                self?.deactivate()
            }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                EventLog.shared.log("unlocked")
                self?.screenLocked = false
                self?.restartCapture()
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { EventLog.shared.log("screensDidWake", self?.sensor.readOnce()); self?.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    private func willSleep() {
        systemAsleep = true
        clamshellClosedAtSleep = Clamshell.isClosed
        EventLog.shared.log("willSleep", sensor.angle, clamshellClosedAtSleep ? 1 : 0)
        restartCapture()
    }

    private var lastWakeHandled: CFTimeInterval = -10
    private func didWake() {
        let now = CACurrentMediaTime()
        systemAsleep = false
        guard now - lastWakeHandled > 2 else { return }   // didWake and screensDidWake both arrive
        lastWakeHandled = now
        restartCapture()
        EventLog.shared.log("didWake", sensor.readOnce(), Clamshell.isClosed ? 1 : 0)
        if !sensor.isAvailable { _ = sensor.openDevice() }
        status.sensorStatus = sensor.statusText
        if inputMode == .sensor, sensor.isAvailable, let a = sensor.readOnce() {
            sensor.resetSmoothing()
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
        EventLog.shared.log("screensChanged", sensor.angle, builtInPresent ? 1 : 0)
        if !builtInPresent {
            deactivate()
            window?.close(); window = nil; mtkView = nil
            stopCapture()
        } else {
            if let screen = Displays.builtInScreen, let w = window, w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
            restartCapture()   // the display may have been re-created; never keep a stream bound to the old one
        }
        evaluate()
    }
}

@MainActor
final class IconState: ObservableObject {
    @Published var active = false
}

@MainActor
final class LiveStatus: ObservableObject {
    @Published var angle: Double?
    @Published var progress: Double = 1
    @Published var sensorStatus: String = ""
    @Published var captureStatus: String = "대기"
    @Published var overlayVisible = false
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
