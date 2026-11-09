import Foundation
import Metal
import MetalKit
import CoreVideo

/// Uniform block shared with `effect_fs` (layout must match Shaders.metal).
struct EffectUniforms {
    var blurAmount: Float = 0
    var uniformDark: Float = 0
    var edgeDark: Float = 0
    var blurStart: Float = 0
    var blurEnd: Float = 1
    var blurCurve: Float = 1
    var hingeBlur: Float = 0
    var maxLod: Float = 10
    var shadeStart: Float = 0
    var shadeCurve: Float = 1
    var sideShade: Float = 0
    var sideWidth: Float = 0.1
    var minShading: Float = 0
    var maxLevel: Float = 0
    var direction: Int32 = 0
    var filterMode: Int32 = 0
    var hasSource: Int32 = 0
}

/// Uniform block shared with `cover_fs` (layout must match Shaders.metal).
struct CoverUniforms {
    var tilt: Float = 0
    var camDist: Float = 3.5
    var camHeight: Float = 0.5
    var aspect: Float = 1.5
    var wipe: Float = 0
    var lodOffset: Float = 0
    var maxLevel: Float = 0
    var contentShift: Float = 0
    var blurGain: Float = 2.5
    var blurStart: Float = 0
    var blurEnd: Float = 0.9
    var lodScale: Float = 8
    var shadeLow: Float = 0.25
    var wipeShadeGain: Float = 2.75
    var edgeBand: Float = 0.1
    var edgeFadeWipe: Float = 0.1
    var hasSource: Int32 = 0
    var towardHinge: Int32 = 1
    var keepHeight: Int32 = 1
}

/// Builds a blur pyramid from a source texture and composites the gradient blur + shading.
final class EffectRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let effectPipeline: MTLRenderPipelineState
    private let coverPipeline: MTLRenderPipelineState
    private let tentPipeline: MTLComputePipelineState
    private let boxPipeline: MTLComputePipelineState
    /// Level 0 is the source itself (sampled straight from the captured IOSurface, no copy);
    /// `pyramid` holds levels 1...N (its mip k is overall level k + 1) in half float.
    private(set) var source: MTLTexture?
    private(set) var pyramid: MTLTexture?
    private var levelViews: [MTLTexture] = []
    private(set) var hasSource = false
    let colorPixelFormat: MTLPixelFormat

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        guard let device else { throw RendererError.noDevice }
        self.device = device
        self.colorPixelFormat = colorPixelFormat
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        self.queue = queue
        let library: MTLLibrary
        if let l = try? device.makeDefaultLibrary(bundle: Bundle(for: EffectRenderer.self)) { library = l }
        else if let l = device.makeDefaultLibrary() { library = l }
        else {
            let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            library = try device.makeLibrary(URL: exeDir.appendingPathComponent("default.metallib"))
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "fullscreen_vs")
        desc.fragmentFunction = library.makeFunction(name: "effect_fs")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        effectPipeline = try device.makeRenderPipelineState(descriptor: desc)
        desc.fragmentFunction = library.makeFunction(name: "cover_fs")
        coverPipeline = try device.makeRenderPipelineState(descriptor: desc)
        tentPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "downsample_tent")!)
        boxPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "downsample_box")!)
    }

    enum RendererError: Error { case noDevice, textureFailure }

    private func ensurePyramid(sourceWidth: Int, sourceHeight: Int) {
        let width = max(1, sourceWidth / 2), height = max(1, sourceHeight / 2)
        if let p = pyramid, p.width == width, p.height == height { return }
        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true)
        d.mipmapLevelCount = levels
        d.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        d.storageMode = .private
        pyramid = device.makeTexture(descriptor: d)
        levelViews = (0..<levels).map { pyramid!.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1)! }
    }

    /// Rebuilds the blur levels for a new source frame. The source must stay alive until the
    /// command buffers that sample it have completed (callers keep the capture buffer referenced).
    func encodePyramid(from src: MTLTexture, filter: BlurFilter, into cb: MTLCommandBuffer) {
        ensurePyramid(sourceWidth: src.width, sourceHeight: src.height)
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        let pso = filter == .smooth ? tentPipeline : boxPipeline   // .reference and .mipmap use box mipmaps
        enc.setComputePipelineState(pso)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        var prev: MTLTexture = src
        for v in levelViews {
            enc.setTexture(prev, index: 0)
            enc.setTexture(v, index: 1)
            enc.dispatchThreads(MTLSize(width: v.width, height: v.height, depth: 1), threadsPerThreadgroup: tg)
            prev = v
        }
        enc.endEncoding()
        source = src
        hasSource = true
    }

    private var maxLevelValue: Float { Float(pyramid?.mipmapLevelCount ?? 0) }

    func invalidateSource() { hasSource = false; source = nil }

    /// Fold progress p: 1 = open (no effect), 0 = closed.
    func uniforms(params: EffectParams, progress p: Double) -> EffectUniforms {
        var u = EffectUniforms()
        let closing = max(0, min(1, 1 - p))
        u.blurAmount = Float(params.blurAmount(closing: closing))
        u.uniformDark = Float(min(1, params.uniformDarkening(closing: closing)))
        u.edgeDark = Float(min(1, params.edgeDarkening(closing: closing)))
        u.blurStart = Float(params.blurStart)
        u.blurEnd = Float(params.blurEnd)
        u.blurCurve = Float(params.blurCurve)
        u.hingeBlur = Float(params.hingeBlur)
        var maxLod = params.maxBlur
        if params.scaleToPanel, let src = source, params.maxBlur > 0 {
            // The fold-perpendicular axis of a MacBook display is its height.
            let offset = log2(Double(src.height) / EffectParams.referencePanelTexels)
            maxLod = params.maxBlur + offset
        }
        u.maxLod = Float(maxLod)
        u.shadeStart = Float(params.shadeStart)
        u.shadeCurve = Float(params.shadeCurve)
        u.sideShade = Float(params.sideShade)
        u.sideWidth = Float(params.sideWidth)
        u.minShading = Float(params.minShading)
        u.maxLevel = maxLevelValue
        u.direction = params.direction == .towardOuterEdge ? 0 : 1
        u.filterMode = params.filter == .mipmap ? 1 : 0
        u.hasSource = hasSource ? 1 : 0
        return u
    }

    func coverUniforms(params: EffectParams, progress p: Double) -> CoverUniforms {
        var u = CoverUniforms()
        let closing = max(0, min(1, 1 - p))
        let tiltDeg = min(90, params.coverTiltMax * closing)
        u.tilt = Float(tiltDeg * .pi / 180)
        u.camDist = Float(params.coverCameraDistance)
        let f = tiltDeg / 90
        u.camHeight = Float(params.coverCameraHeightStart + (params.coverCameraHeightEnd - params.coverCameraHeightStart) * f)
        if let src = source {
            u.aspect = Float(Double(src.width) / Double(src.height))
            u.lodOffset = Float(log2(Double(src.height) / max(1, params.coverReferencePx)))
            u.maxLevel = maxLevelValue
        }
        u.wipe = Float(params.coverWipeAtFullTilt * tiltDeg / 90)
        u.contentShift = Float(params.coverContentShift)
        u.blurGain = Float(params.coverBlurGain)
        u.blurStart = Float(params.coverBlurStart)
        u.blurEnd = Float(params.coverBlurEnd)
        u.lodScale = Float(params.coverLodScale)
        u.shadeLow = Float(params.coverShadeLow)
        u.wipeShadeGain = Float(params.coverWipeShadeGain)
        u.edgeBand = Float(params.coverEdgeBand)
        u.hasSource = hasSource ? 1 : 0
        u.towardHinge = params.coverTowardHinge ? 1 : 0
        u.keepHeight = params.coverKeepHeight ? 1 : 0
        u.edgeFadeWipe = Float(params.coverEdgeFadeWipe)
        return u
    }

    func encodeEffect(params: EffectParams, progress: Double, pass: MTLRenderPassDescriptor, into cb: MTLCommandBuffer) {
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        if params.style == .coverPanel {
            var u = coverUniforms(params: params, progress: progress)
            enc.setRenderPipelineState(coverPipeline)
            if let src = source, let pyr = pyramid { enc.setFragmentTexture(src, index: 0); enc.setFragmentTexture(pyr, index: 1) } else { u.hasSource = 0 }
            enc.setFragmentBytes(&u, length: MemoryLayout<CoverUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            return
        }
        var u = uniforms(params: params, progress: progress)
        enc.setRenderPipelineState(effectPipeline)
        if let src = source, let pyr = pyramid { enc.setFragmentTexture(src, index: 0); enc.setFragmentTexture(pyr, index: 1) } else { u.hasSource = 0 }
        enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}

/// Wraps IOSurface-backed CVPixelBuffers (from ScreenCaptureKit) as Metal textures without copying.
final class PixelBufferTextureCache {
    private var cache: CVMetalTextureCache?
    init(device: MTLDevice) {
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }
    func texture(for pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard let cache else { return nil }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (tex, cvTex)
    }
    func flush() { if let cache { CVMetalTextureCacheFlush(cache, 0) } }
}
