// lidblur-render — offline renderer used to tune the effect against reference stills.
// usage: lidblur-render <in.png> <out.png> <progress> [key=value ...]
//        progress may be a comma-separated list; then <out.png> must contain "%p".
import Foundation
import Metal
import MetalKit
import ImageIO
import UniformTypeIdentifiers

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let args = CommandLine.arguments
guard args.count >= 4 else { fail("usage: lidblur-render in.png out.png progress[,progress...] [key=value ...]") }
let inURL = URL(fileURLWithPath: args[1])
let outPattern = args[2]
let progresses = args[3].split(separator: ",").compactMap { Double($0) }

var params = EffectParams.default
if args.count > 4 {
    var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as! [String: Any]
    for kv in args[4...] {
        let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { fail("bad override \(kv)") }
        if let d = Double(parts[1]) { dict[parts[0]] = d }
        else if parts[1] == "true" || parts[1] == "false" { dict[parts[0]] = parts[1] == "true" }
        else { dict[parts[0]] = parts[1] }
    }
    params = try JSONDecoder().decode(EffectParams.self, from: JSONSerialization.data(withJSONObject: dict))
}

let renderer = try EffectRenderer()
let loader = MTKTextureLoader(device: renderer.device)
let src = try loader.newTexture(URL: inURL, options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue, .textureStorageMode: MTLStorageMode.private.rawValue])

let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: src.width, height: src.height, mipmapped: false)
od.usage = [.renderTarget, .shaderRead]
od.storageMode = .shared
let out = renderer.device.makeTexture(descriptor: od)!

do {
    let cb = renderer.queue.makeCommandBuffer()!
    renderer.encodePyramid(from: src, filter: params.filter, into: cb)
    cb.commit(); cb.waitUntilCompleted()
}

for p in progresses {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = out
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let cb = renderer.queue.makeCommandBuffer()!
    renderer.encodeEffect(params: params, progress: p, pass: pass, into: cb)
    cb.commit(); cb.waitUntilCompleted()

    let bpr = out.width * 4
    var bytes = [UInt8](repeating: 0, count: bpr * out.height)
    out.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, out.width, out.height), mipmapLevel: 0)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    let ctx = CGContext(data: &bytes, width: out.width, height: out.height, bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info.rawValue)!
    let img = ctx.makeImage()!
    let path = outPattern.replacingOccurrences(of: "%p", with: String(format: "%03d", Int((p * 100).rounded())))
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print(path)
}
