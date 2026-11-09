import Foundation

/// Which edge of the built-in display the blur/shading gradient grows toward.
/// In the reference effect the gradient grows toward the outer (free) edge of the panel
/// that tilts toward the viewer. On a MacBook the outer edge of the lid is the top of the screen.
enum GradientDirection: String, Codable, CaseIterable, Identifiable {
    case towardOuterEdge   // top of the display
    case towardHinge       // bottom of the display
    var id: String { rawValue }
}

/// Overall look.
enum EffectStyle: String, Codable, CaseIterable, Identifiable {
    case coverPanel   // the display tilts like a folding phone's outer display (trapezoid + blur + shading)
    case gradient     // flat gradient blur + shading only (no geometry)
    var id: String { rawValue }
}

/// How blurred levels are reconstructed.
enum BlurFilter: String, Codable, CaseIterable, Identifiable {
    case reference // box mipmaps + B-spline upsampling per level (matches the reference look)
    case smooth   // tent-filtered pyramid + B-spline upsampling (no blocky artifacts)
    case mipmap   // plain box mipmaps + trilinear (closest to a naive textureLod)
    var id: String { rawValue }
}

/// All tunable parameters of the effect. Everything is written from scratch for this app;
/// default values were chosen by visual comparison with the reference page.
struct EffectParams: Codable, Equatable {
    init() {}
    // Decode leniently so settings saved by older builds keep working when fields are added.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        func d<T: Decodable>(_ key: String, _ v: inout T) { if let x = try? c.decode(T.self, forKey: AnyKey(key)) { v = x } }
        d("direction", &direction); d("blurStart", &blurStart); d("blurEnd", &blurEnd); d("blurCurve", &blurCurve)
        d("hingeBlur", &hingeBlur); d("maxBlur", &maxBlur); d("scaleToPanel", &scaleToPanel); d("filter", &filter)
        d("blurBase", &blurBase); d("blurSlope", &blurSlope); d("blurOnset", &blurOnset)
        d("shadeUniform", &shadeUniform); d("shadeUniformCurve", &shadeUniformCurve); d("shadeEdge", &shadeEdge)
        d("shadeEdgeFull", &shadeEdgeFull); d("shadeEdgeCurve", &shadeEdgeCurve); d("shadeStart", &shadeStart)
        d("shadeCurve", &shadeCurve); d("sideShade", &sideShade); d("sideWidth", &sideWidth); d("minShading", &minShading)
        d("style", &style); d("coverTiltMax", &coverTiltMax); d("coverCameraDistance", &coverCameraDistance)
        d("coverCameraHeightStart", &coverCameraHeightStart); d("coverCameraHeightEnd", &coverCameraHeightEnd)
        d("coverWipeAtFullTilt", &coverWipeAtFullTilt); d("coverBlurGain", &coverBlurGain); d("coverBlurStart", &coverBlurStart)
        d("coverBlurEnd", &coverBlurEnd); d("coverLodScale", &coverLodScale); d("coverReferencePx", &coverReferencePx)
        d("coverShadeLow", &coverShadeLow); d("coverWipeShadeGain", &coverWipeShadeGain); d("coverEdgeBand", &coverEdgeBand)
        d("coverContentShift", &coverContentShift); d("coverTowardHinge", &coverTowardHinge)
        d("lerpDrag", &lerpDrag); d("lerpSnap", &lerpSnap)
        d("openAngle", &openAngle); d("closedAngle", &closedAngle); d("angleCurve", &angleCurve)
    }

    var style: EffectStyle = .coverPanel

    // Cover-panel style (values follow the reference effect)
    var coverTiltMax: Double = 90          // degrees of virtual tilt at full close (90 = edge-on)
    var coverCameraDistance: Double = 3.44 // virtual camera distance in display heights
    var coverCameraHeightStart: Double = 0.5   // camera height above the hinge at rest (display heights)
    var coverCameraHeightEnd: Double = 0.28    // ... at full tilt
    var coverWipeAtFullTilt: Double = 0.5  // blur/shade driver at full tilt (= tilt / 180 deg)
    var coverBlurGain: Double = 2.5
    var coverBlurStart: Double = 0.0
    var coverBlurEnd: Double = 0.9
    var coverLodScale: Double = 8
    var coverReferencePx: Double = 775     // size of the reference blur texture across the panel
    var coverShadeLow: Double = 0.25
    var coverWipeShadeGain: Double = 2.75
    var coverEdgeBand: Double = 0.1
    var coverContentShift: Double = 0.23
    var coverTowardHinge: Bool = false

    // Spatial gradient (t = 0 at the hinge, 1 at the outer edge of the lid)
    var direction: GradientDirection = .towardOuterEdge
    var blurStart: Double = 0.0           // where the spatial ramp begins along t
    var blurEnd: Double = 1.0             // where the spatial ramp reaches its maximum
    var blurCurve: Double = 1.4           // pow() exponent of the spatial ramp
    var hingeBlur: Double = 0.45          // fraction of the maximum level-of-detail already present at the hinge
    var maxBlur: Double = 10.0            // maximum level-of-detail (log2 of blur size in reference texels)
    var scaleToPanel: Bool = true         // keep blur size proportional to the panel instead of pixels
    var filter: BlurFilter = .smooth

    // How the fold progress drives the blur (progress p: 1 = open, 0 = closed; c = 1 - p)
    // blur amount = min(1, blurBase + blurSlope * c) * smoothstep(0, blurOnset, c)
    var blurBase: Double = 0.46
    var blurSlope: Double = 2.0
    var blurOnset: Double = 0.1

    // Shading: brightness = (1 - U(c)) * (1 - E(c) * ramp(t)) * side, never below minShading
    //   U(c) = shadeUniform * c^shadeUniformCurve
    //   E(c) = shadeEdge * min(1, (c / shadeEdgeFull)^shadeEdgeCurve)
    //   ramp(t) = saturate((t - shadeStart) / (1 - shadeStart))^shadeCurve
    var shadeUniform: Double = 1.0
    var shadeUniformCurve: Double = 1.5
    var shadeEdge: Double = 1.0
    var shadeEdgeFull: Double = 0.31
    var shadeEdgeCurve: Double = 1.1
    var shadeStart: Double = 0.15
    var shadeCurve: Double = 1.25
    var sideShade: Double = 0.65          // extra darkening toward the left/right edges
    var sideWidth: Double = 0.075         // width of that side band (fraction of the display width)
    var minShading: Double = 0.0          // lower bound of brightness

    // Smoothing (per-frame lerp factors at 60 Hz, corrected for the actual frame time)
    var lerpDrag: Double = 0.2            // following a live input (lid angle, slider)
    var lerpSnap: Double = 0.095          // fallback animations

    // Lid angle -> progress mapping
    var openAngle: Double = 95            // at or above this the effect is off (p = 1)
    var closedAngle: Double = 18          // at or below this the effect is maximal (p = 0)
    var angleCurve: Double = 1.0          // p = lin^curve

    static let `default` = EffectParams()

    /// Texels across one panel of the reference along the fold-perpendicular axis.
    /// Used to keep the blur size proportional when the panel is larger or smaller.
    static let referencePanelTexels: Double = 1335

    func progress(forAngle angle: Double) -> Double {
        let span = max(1, openAngle - closedAngle)
        let lin = min(1, max(0, (angle - closedAngle) / span))
        return pow(lin, max(0.05, angleCurve))
    }
}

extension EffectParams {
    private static let defaultsKey = "EffectParams.v1"

    static func load(from defaults: UserDefaults = .standard) -> EffectParams {
        guard let data = defaults.data(forKey: defaultsKey),
              let p = try? JSONDecoder().decode(EffectParams.self, from: data) else { return .default }
        return p
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Exponential smoothing that behaves the same at 60 Hz and 120 Hz.
@inline(__always)
func frameLerp(_ current: Double, _ target: Double, factor60: Double, dt: Double) -> Double {
    let f = 1 - pow(1 - min(max(factor60, 0), 1), max(dt, 0) * 60)
    return current + (target - current) * f
}

struct AnyKey: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension EffectParams {
    /// Pyramid filter actually used for the current style.
    var effectiveFilter: BlurFilter { style == .coverPanel ? .reference : filter }

    /// Blur amount (0...1) for closing amount c = 1 - progress.
    func blurAmount(closing c: Double) -> Double {
        guard c > 0 else { return 0 }
        let x = min(1, max(0, c / max(blurOnset, 1e-4)))
        let onset = x * x * (3 - 2 * x)
        return min(1, blurBase + blurSlope * c) * onset
    }
    func uniformDarkening(closing c: Double) -> Double { shadeUniform * pow(max(0, c), shadeUniformCurve) }
    func edgeDarkening(closing c: Double) -> Double { shadeEdge * min(1, pow(max(0, c) / max(shadeEdgeFull, 1e-4), shadeEdgeCurve)) }
}
