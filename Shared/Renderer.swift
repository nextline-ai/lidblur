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
    private let copyPipeline: MTLComputePipelineState
    private let tentPipeline: MTLComputePipelineState
    private let boxPipeline: MTLComputePipelineState
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
        copyPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "copy_to_level0")!)
        tentPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "downsample_tent")!)
        boxPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "downsample_box")!)
    }

    enum RendererError: Error { case noDevice, textureFailure }

    private func ensurePyramid(width: Int, height: Int) {
        if let p = pyramid, p.width == width, p.height == height { return }
        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true)
        d.mipmapLevelCount = levels
        d.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        d.storageMode = .private
        pyramid = device.makeTexture(descriptor: d)
        levelViews = (0..<levels).map { pyramid!.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1)! }
    }

    /// Rebuilds the pyramid from a new source frame.
    func encodePyramid(from source: MTLTexture, filter: BlurFilter, into cb: MTLCommandBuffer) {
        ensurePyramid(width: source.width, height: source.height)
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        func dispatch(_ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: tg)
        }
        enc.setComputePipelineState(copyPipeline)
        enc.setTexture(source, index: 0)
        enc.setTexture(levelViews[0], index: 1)
        dispatch(copyPipeline, levelViews[0].width, levelViews[0].height)
        let pso = filter == .smooth ? tentPipeline : boxPipeline   // .reference and .mipmap use box mipmaps
        enc.setComputePipelineState(pso)
        for i in 1..<levelViews.count {
            enc.setTexture(levelViews[i - 1], index: 0)
            enc.setTexture(levelViews[i], index: 1)
            dispatch(pso, levelViews[i].width, levelViews[i].height)
        }
        enc.endEncoding()
        hasSource = true
    }

    func invalidateSource() { hasSource = false }

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
        if params.scaleToPanel, let pyr = pyramid, params.maxBlur > 0 {
            // The fold-perpendicular axis of a MacBook display is its height.
            let offset = log2(Double(pyr.height) / EffectParams.referencePanelTexels)
            maxLod = params.maxBlur + offset
        }
        u.maxLod = Float(maxLod)
        u.shadeStart = Float(params.shadeStart)
        u.shadeCurve = Float(params.shadeCurve)
        u.sideShade = Float(params.sideShade)
        u.sideWidth = Float(params.sideWidth)
        u.minShading = Float(params.minShading)
        u.maxLevel = Float((pyramid?.mipmapLevelCount ?? 1) - 1)
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
        if let pyr = pyramid {
            u.aspect = Float(Double(pyr.width) / Double(pyr.height))
            u.lodOffset = Float(log2(Double(pyr.height) / max(1, params.coverReferencePx)))
            u.maxLevel = Float(pyr.mipmapLevelCount - 1)
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
            if let pyr = pyramid { enc.setFragmentTexture(pyr, index: 0) } else { u.hasSource = 0 }
            enc.setFragmentBytes(&u, length: MemoryLayout<CoverUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            return
        }
        var u = uniforms(params: params, progress: progress)
        enc.setRenderPipelineState(effectPipeline)
        if let pyr = pyramid { enc.setFragmentTexture(pyr, index: 0) } else { u.hasSource = 0 }
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
