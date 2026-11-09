import SwiftUI
import MetalKit
import UniformTypeIdentifiers

/// Side-by-side still comparison: render the effect on a source image (e.g. a screenshot of the reference
/// fully open) and show it next to a reference screenshot taken at the same progress.
struct CompareView: View {
    @ObservedObject var engine: EffectEngine
    @StateObject private var model = CompareModel()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("원본 이미지(펼친 상태)…") { model.pick { model.sourceURL = $0 } }
                Text(model.sourceURL?.lastPathComponent ?? "없음").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("비교 이미지(같은 진행도)…") { model.pick { model.referenceURL = $0 } }
                Text(model.referenceURL?.lastPathComponent ?? "없음").foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Picker("덮개 끝(블러가 강해지는 쪽)", selection: $model.outerEdge) {
                    ForEach(CompareModel.Edge.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 360)
                Spacer()
                ParamSlider("진행도", value: $model.progress, range: 0...1, format: "%.3f").frame(maxWidth: 420)
            }
            HStack(spacing: 8) {
                panel(title: "LidBlur 렌더", image: model.rendered)
                panel(title: "비교 이미지", image: model.reference)
            }
        }
        .padding()
        .onChange(of: model.sourceURL) { _, _ in model.loadSource(); model.render(params: engine.params) }
        .onChange(of: model.referenceURL) { _, _ in model.loadReference() }
        .onChange(of: model.outerEdge) { _, _ in model.loadSource(); model.render(params: engine.params) }
        .onChange(of: model.progress) { _, _ in model.render(params: engine.params) }
        .onChange(of: engine.params) { _, p in model.render(params: p) }
    }

    @ViewBuilder private func panel(title: String, image: NSImage?) -> some View {
        VStack {
            Text(title).font(.headline)
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            }
        }
    }
}

@MainActor
final class CompareModel: ObservableObject {
    enum Edge: Int, CaseIterable, Identifiable {
        case top = 0, left = 1, bottom = 2, right = 3
        var id: Int { rawValue }
        var label: String { ["위쪽", "왼쪽", "아래쪽", "오른쪽"][rawValue] }
    }
    @Published var sourceURL: URL?
    @Published var referenceURL: URL?
    @Published var outerEdge: Edge = .top
    @Published var progress: Double = 0.8
    @Published private(set) var rendered: NSImage?
    @Published private(set) var reference: NSImage?

    private let renderer = try? EffectRenderer()
    private var sourceTexture: MTLTexture?
    private var output: MTLTexture?
    private var pyramidFilter: BlurFilter?

    func pick(_ done: @escaping (URL) -> Void) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        if p.runModal() == .OK, let u = p.url { done(u) }
    }

    func loadReference() {
        reference = referenceURL.flatMap { NSImage(contentsOf: $0) }
    }

    func loadSource() {
        guard let url = sourceURL, let renderer,
              let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // Rotate so the panel's outer edge is at the top (the renderer's convention), limit the size.
        guard let upright = ImageOps.rotate(img, quarterTurnsCW: outerEdge.rawValue),
              let scaled = ImageOps.fit(upright, maxDimension: 1800) else { return }
        let loader = MTKTextureLoader(device: renderer.device)
        sourceTexture = try? loader.newTexture(cgImage: scaled, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
        pyramidFilter = nil
        if let s = sourceTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: s.width, height: s.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            output = renderer.device.makeTexture(descriptor: d)
        }
    }

    func render(params: EffectParams) {
        guard let renderer, let src = sourceTexture, let out = output, let cb = renderer.queue.makeCommandBuffer() else { return }
        if pyramidFilter != params.effectiveFilter {
            renderer.encodePyramid(from: src, filter: params.effectiveFilter, into: cb)
            pyramidFilter = params.effectiveFilter
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        renderer.encodeEffect(params: params, progress: progress, pass: pass, into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        guard let cg = ImageOps.cgImage(from: out),
              let back = ImageOps.rotate(cg, quarterTurnsCW: (4 - outerEdge.rawValue) % 4) else { return }
        rendered = NSImage(cgImage: back, size: NSSize(width: back.width, height: back.height))
    }
}

enum ImageOps {
    static func rotate(_ img: CGImage, quarterTurnsCW q: Int) -> CGImage? {
        let q = ((q % 4) + 4) % 4
        if q == 0 { return img }
        let w = img.width, h = img.height
        let (ow, oh) = q % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(ow) / 2, y: CGFloat(oh) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    static func fit(_ img: CGImage, maxDimension: Int) -> CGImage? {
        let m = max(img.width, img.height)
        guard m > maxDimension else { return img }
        let s = Double(maxDimension) / Double(m)
        let w = Int(Double(img.width) * s), h = Int(Double(img.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func cgImage(from tex: MTLTexture) -> CGImage? {
        let bpr = tex.width * 4
        var bytes = [UInt8](repeating: 0, count: bpr * tex.height)
        tex.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: tex.width, height: tex.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
