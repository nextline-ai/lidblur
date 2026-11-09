#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// LidBlur shaders — gradient level-of-detail blur + shading.
// Original implementation for this project.
// ---------------------------------------------------------------------------

struct VOut {
    float4 pos [[position]];
    float2 uv;          // (0,0) = top-left of the display
};

vertex VOut fullscreen_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Copy the captured frame (8-bit BGRA) into level 0 of the half-float pyramid.
kernel void copy_to_level0(texture2d<float, access::read>  src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 s = uint2(float2(gid) * float2(src.get_width(), src.get_height()) / float2(dst.get_width(), dst.get_height()));
    dst.write(src.read(s), gid);
}

// 2x downsample with a separable [1 3 3 1] tent kernel (4 bilinear taps at +-0.75 texel).
// Produces a gaussian-like pyramid that stays smooth when magnified.
kernel void downsample_tent(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write>  dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    uint dw = dst.get_width(), dh = dst.get_height();
    if (gid.x >= dw || gid.y >= dh) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 scale = float2(src.get_width(), src.get_height()) / float2(dw, dh);
    float2 c = (float2(gid) + 0.5) * scale;
    float2 o = 0.75 * scale * 0.5;   // 0.75 source texel when scale == 2
    float4 a = src.sample(s, c + float2(-o.x, -o.y)) + src.sample(s, c + float2(o.x, -o.y))
             + src.sample(s, c + float2(-o.x,  o.y)) + src.sample(s, c + float2(o.x,  o.y));
    dst.write(a * 0.25, gid);
}

// Plain 2x2 box downsample (classic mipmap).
kernel void downsample_box(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint dw = dst.get_width(), dh = dst.get_height();
    if (gid.x >= dw || gid.y >= dh) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::pixel);
    float2 scale = float2(src.get_width(), src.get_height()) / float2(dw, dh);
    float2 c = (float2(gid) + 0.5) * scale;
    dst.write(src.sample(s, c), gid);
}

struct EffectUniforms {
    float blurAmount;      // 0..1, from fold progress
    float uniformDark;     // 0..1, darkening everywhere
    float edgeDark;        // 0..1, darkening that grows with t
    float blurStart;
    float blurEnd;
    float blurCurve;
    float hingeBlur;
    float maxLod;          // in pyramid levels (already scaled to the panel)
    float shadeStart;
    float shadeCurve;
    float sideShade;
    float sideWidth;
    float minShading;
    float maxLevel;        // highest pyramid level available
    int   direction;       // 0 = outer edge is uv.y == 0 (top), 1 = hinge side (bottom)
    int   filterMode;      // 0 = smooth, 1 = mipmap
    int   hasSource;       // 0 => render black (no captured frame yet)
};

// Bilinear sample of one pyramid level.
static float4 sample_level_linear(texture2d<float> t, float2 uv, float lvl) {
    constexpr sampler s(filter::linear, mip_filter::nearest, address::clamp_to_edge);
    return t.sample(s, uv, level(lvl));
}

// Cubic B-spline sample of one pyramid level using 4 bilinear taps.
static float4 sample_level_bspline(texture2d<float> t, float2 uv, uint lvl) {
    constexpr sampler s(filter::linear, mip_filter::nearest, address::clamp_to_edge);
    float2 size = float2(max(1u, t.get_width() >> lvl), max(1u, t.get_height() >> lvl));
    float2 p = uv * size - 0.5;
    float2 i = floor(p);
    float2 f = p - i;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    float2 w3 = f3 / 6.0;
    float2 g0 = w0 + w1;
    float2 g1 = w2 + w3;
    float2 h0 = (i - 1.0 + w1 / g0 + 0.5) / size;
    float2 h1 = (i + 1.0 + w3 / g1 + 0.5) / size;
    float l = float(lvl);
    float4 a = t.sample(s, float2(h0.x, h0.y), level(l));
    float4 b = t.sample(s, float2(h1.x, h0.y), level(l));
    float4 c = t.sample(s, float2(h0.x, h1.y), level(l));
    float4 d = t.sample(s, float2(h1.x, h1.y), level(l));
    return g0.y * (g0.x * a + g1.x * b) + g1.y * (g0.x * c + g1.x * d);
}

static float4 sample_lod(texture2d<float> t, float2 uv, float lod, float maxLevel, int mode) {
    lod = clamp(lod, 0.0, maxLevel);
    if (mode == 1) {
        constexpr sampler tri(filter::linear, mip_filter::linear, address::clamp_to_edge);
        return t.sample(tri, uv, level(lod));
    }
    float l0 = floor(lod);
    float fr = lod - l0;
    uint i0 = uint(l0);
    float4 a = (i0 == 0) ? sample_level_linear(t, uv, 0.0) : sample_level_bspline(t, uv, i0);
    if (fr < 1e-4) return a;
    float4 b = sample_level_bspline(t, uv, min(i0 + 1, uint(maxLevel)));
    return mix(a, b, fr);
}

fragment float4 effect_fs(VOut in [[stage_in]],
                          texture2d<float> pyramid [[texture(0)]],
                          constant EffectUniforms& u [[buffer(0)]]) {
    if (u.hasSource == 0) return float4(0, 0, 0, 1);

    // t: 0 at the hinge (bottom of a MacBook display), 1 at the lid's outer edge (top).
    float t = 1.0 - in.uv.y;
    if (u.direction == 1) t = in.uv.y;   // gradient grows toward the hinge instead

    float span = max(u.blurEnd - u.blurStart, 1e-4);
    float n = saturate((t - u.blurStart) / span);
    float ramp = pow(n, max(u.blurCurve, 0.01));

    float lod = u.blurAmount * u.maxLod * (u.hingeBlur + (1.0 - u.hingeBlur) * ramp);
    float4 c = sample_lod(pyramid, in.uv, lod, u.maxLevel, u.filterMode);

    float st = saturate((t - u.shadeStart) / max(1.0 - u.shadeStart, 1e-4));
    float edge = pow(st, max(u.shadeCurve, 0.01));
    float sd = 1.0 - smoothstep(0.0, max(u.sideWidth, 1e-4), min(in.uv.x, 1.0 - in.uv.x));
    float shade = (1.0 - u.uniformDark) * (1.0 - u.edgeDark * edge) * (1.0 - u.edgeDark * u.sideShade * sd * sd);
    shade = max(shade, u.minShading);
    return float4(c.rgb * shade, 1.0);
}

// ---------------------------------------------------------------------------
// Cover-panel style: the display content is treated as a panel hinged at the bottom edge that
// tilts toward the viewer (like the outer display of a folding phone swinging shut).
// Each pixel casts a ray from a virtual camera and intersects the tilted panel, which gives the
// exact trapezoid and foreshortening. Blur and shading grow toward the hinge with the tilt.
// ---------------------------------------------------------------------------

struct CoverUniforms {
    float tilt;            // radians, 0 = flat (identity), pi/2 = edge-on
    float camDist;         // camera distance in display heights
    float camHeight;       // camera height above the hinge in display heights
    float aspect;          // display width / height
    float wipe;            // 0..0.5, drives blur + shading (tilt / pi)
    float lodOffset;       // log2(display height / reference blur texture size)
    float maxLevel;
    float contentShift;    // content slides toward the outer edge by contentShift * wipe
    float blurGain;
    float blurStart;
    float blurEnd;
    float lodScale;
    float shadeLow;
    float wipeShadeGain;
    float edgeBand;
    int   hasSource;
    int   towardHinge;     // 1: blur/shade grow toward the hinge (reference), 0: toward the outer edge
};

fragment float4 cover_fs(VOut in [[stage_in]],
                         texture2d<float> pyramid [[texture(0)]],
                         constant CoverUniforms& u [[buffer(0)]]) {
    if (u.hasSource == 0) return float4(0, 0, 0, 1);

    // World units = display height. Hinge along y = 0, z = 0; the display (image plane) is z = 0, y in [0, 1].
    // The camera sits at (0, camHeight, camDist) and looks through the display as a window (off-axis),
    // so the hinge always stays on the display's bottom edge. The panel tilts with its outer edge
    // receding: panel point (x, q) -> (x, q cos t, -q sin t).
    float A = u.aspect, D = u.camDist, hc = u.camHeight;
    float X = (in.uv.x - 0.5) * A;
    float Ys = 1.0 - in.uv.y;
    float st = sin(u.tilt), ct = cos(u.tilt);
    float num = hc * st + D * ct;
    float den = D * ct - (Ys - hc) * st;
    if (den <= 1e-6) return float4(0, 0, 0, 1);
    float lam = num / den;
    if (lam <= 0.0) return float4(0, 0, 0, 1);
    float3 P = float3(lam * X, hc + lam * (Ys - hc), D * (1.0 - lam));
    float q = P.y * ct - P.z * st;                    // distance from the hinge along the panel
    float2 tuv = float2(P.x / A + 0.5, 1.0 - q);      // panel texture coordinate (y down)

    // Anti-aliased panel coverage.
    float2 fw = max(fwidth(tuv), float2(1e-6));
    float cov = smoothstep(0.0, fw.x, tuv.x) * smoothstep(0.0, fw.x, 1.0 - tuv.x)
              * smoothstep(0.0, fw.y, tuv.y) * smoothstep(0.0, fw.y, 1.0 - tuv.y);
    if (cov <= 0.0) return float4(0, 0, 0, 1);

    // Distance from the outer edge (0) to the hinge (1).
    float d = u.towardHinge != 0 ? tuv.y : 1.0 - tuv.y;
    float n = saturate((d - u.blurStart) / max(u.blurEnd - u.blurStart, 1e-4) * u.wipe * u.blurGain);
    float blurArea = sqrt(n / 0.75);
    float lodBlur = blurArea * u.lodScale;
    lodBlur += u.lodOffset * saturate(lodBlur);         // keep native sharpness when there is no blur

    // Content slides slightly as the panel tilts.
    float shiftDir = u.towardHinge != 0 ? 1.0 : -1.0;
    float2 suv = tuv + float2(0.0, shiftDir * u.contentShift * u.wipe);

    // Perspective minification so the foreshortened panel does not alias.
    float2 size = float2(pyramid.get_width(), pyramid.get_height());
    float2 dx = dfdx(suv * size), dy = dfdy(suv * size);
    float lodPersp = 0.5 * log2(max(max(dot(dx, dx), dot(dy, dy)), 1e-8));
    float lod = max(lodBlur, lodPersp);
    float4 c = sample_lod(pyramid, saturate(suv), lod, u.maxLevel, 0);

    // Shading: blur-linked darkening, darkening toward the hinge, and the panel's side edges.
    float shade = mix(u.shadeLow, 1.0, smoothstep(1.3, 0.9, blurArea));
    shade *= smoothstep(1.0, 1.0 - u.edgeBand, abs(tuv.x - 0.5) * 2.0);
    shade *= 1.0 - saturate(u.wipe * u.wipeShadeGain) * smoothstep(0.0, 1.0, d);
    float edges = smoothstep(1.1, 1.0, suv.y) * smoothstep(-0.1, 0.0, suv.y);
    return float4(c.rgb * shade * edges * cov, 1.0);
}
