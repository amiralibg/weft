import Foundation

/// Metal source for `ZipperView`, compiled when Setup first opens — a string
/// for the same reason as `LoomShader`: no Metal Toolchain needed to build.
enum ZipperShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// The cloth over Setup's stage, zipped shut down the middle.
//
// Two halves of dark woven cloth meet at a metal zip. The slider rides down
// the chain as Setup goes on; above it the halves part in a V and the loom
// behind shows through. Once the slider runs off the bottom the halves swing
// apart and off the stage, uncovering whatever is underneath. Where there is
// no cloth, tooth or hardware the layer is transparent: it only ever covers,
// or shades, what lies below it. Output is premultiplied.
// Coordinates are in "height units": y runs 0…1 down the view, x 0…aspect.

struct Uniforms {
    float2 size;
    float2 pointer;
    float time;
    float sliderY;
    float release;
    float tabAngle;
    float pointerStrength;
    float contentScale;
    float4 accent;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut zipperVertex(uint id [[vertex_id]]) {
    // One triangle that covers the whole view.
    float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(corners[id], 0, 1);
    return out;
}

static float hash11(float n) {
    return fract(sin(n * 127.1) * 43758.5453);
}

static float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

static float sdRoundBox(float2 q, float2 b, float r) {
    float2 d = abs(q) - b + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

static float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Premultiplied `src` over `dst`.
static float4 over(float4 dst, float4 src) {
    return src + dst * (1.0 - src.a);
}

constant float kReach = 0.0095;   // how far a tooth reaches past the centre line
constant float kRoot = 0.005;     // how deep a tooth is clamped into its tape
constant float kPitch = 0.0165;   // tooth to tooth down the chain, left and right in turn
constant float kTape = 0.026;     // the woven tape each row of teeth is clamped to
constant float kWeave = 1.0 / 170.0;
constant float kMaxOpen = 0.30;   // half-width of the gap, far above the slider
constant float kPartAt = 0.03;    // from the slider's centre up to where the chain parts
constant float3 kLight = float3(-0.45, -0.65, 0.62);  // from the top left, towards us

// How far the left half's edge has moved out from where it sits zipped, at
// height y, and how fast that changes down the screen (the edge's slope).
static float spreadAt(float y, float sliderY, float release, float c, float t, thread float &slope) {
    float d = sliderY - kPartAt - y;
    float spread = 0.0;
    slope = 0.0;
    if (d > 0.0) {
        // Eased in, so the edge leaves the chain along it rather than at an
        // angle: a kink in the edge is a kink in the whole half of the cloth.
        float s = d * d / (d + 0.06);
        float ds = d * (d + 0.12) / ((d + 0.06) * (d + 0.06));
        float e = exp(-s * 2.4);
        spread = kMaxOpen * (1.0 - e);
        slope = kMaxOpen * 2.4 * e * ds;
        // The halves hang loose above the slider and stir a little.
        spread += sin(t * 0.8 + y * 5.0) * 0.002 * smoothstep(0.0, 0.12, d);
    }
    // Undone: both halves swing out and away, the top leading.
    float part = release * (c + 0.14);
    spread += part * (1.0 + 0.4 * (1.0 - y));
    slope += part * 0.4;
    return spread;
}

struct Half {
    float4 cloth;   // tape and fabric, premultiplied
    float4 teeth;   // premultiplied
    float shade;    // the shadow this half casts into the gap, 0…1
};

// One half of the cloth, its tape and its row of teeth. Drawn as the left
// half; the right one is its mirror image, with its teeth one pitch down.
static Half halfAt(float2 p, float side, float c, float aspect, float aa,
                   float3 accent, float2 pointer, constant Uniforms &u) {
    Half h;
    float t = u.time;
    float2 m = side < 0.5 ? p : float2(2.0 * c - p.x, p.y);
    float mirror = side < 0.5 ? 1.0 : -1.0;
    float3 l = normalize(kLight);
    float3 hv = normalize(l + float3(0.0, 0.0, 1.0));

    float slope;
    float spread = spreadAt(m.y, u.sliderY, u.release, c, t, slope);
    float edge = c - kReach - spread;          // the tape's edge, where the teeth are clamped
    float stretch = sqrt(1.0 + slope * slope);
    float dx = m.x - edge;
    float across = dx / stretch;               // > 0 out towards the gap
    float along = m.y + dx * slope / (stretch * stretch);
    float openHere = smoothstep(0.0, 0.04, spread);

    float2 centered = (p - float2(c, 0.5)) / float2(aspect, 1.0);
    float vignette = 1.0 - dot(centered, centered) * 0.9;

    // ---- The cloth: a tape along the edge, woven fabric beyond it. The tape
    // follows the edge's slant; the fabric only slides sideways with it, so the
    // weave is never skewed or stretched and reads as one cloth top to bottom.
    float inside = 1.0 - smoothstep(-aa, aa, across);
    float depth = -across;

    float cellX = -dx / kWeave;
    float cellY = m.y / kWeave;
    float column = floor(cellX);
    float row = floor(cellY);
    float ax = fract(cellX) - 0.5;
    float ay = fract(cellY) - 0.5;
    bool warpOnTop = fmod(abs(column + row), 2.0) < 1.0;
    float3 warp = float3(0.095, 0.105, 0.15) * (0.85 + 0.3 * hash11(column + side * 97.0));
    float3 weft = mix(float3(0.08, 0.09, 0.14), accent * 0.3, 0.3) * (0.85 + 0.3 * hash11(row * 1.7 + 13.0));
    float3 fabric = warpOnTop
        ? warp * (0.72 + 0.34 * sqrt(max(0.0, 1.0 - 4.0 * ax * ax))) * (0.86 + 0.14 * cos(ay * 2.8))
        : weft * (0.72 + 0.34 * sqrt(max(0.0, 1.0 - 4.0 * ay * ay))) * (0.86 + 0.14 * cos(ax * 2.8));
    // Slow folds in the drape.
    fabric *= 0.9 + 0.1 * sin(-dx * 7.0 + m.y * 2.3 + 0.6 * sin(m.y * 5.0 + t * 0.15));
    // Where it is open the cloth lifts at the edge and catches the light below.
    fabric += accent * 0.1 * exp(-(depth - kTape) / 0.05) * openHere;

    float ribs = 0.5 + 0.5 * cos(along / 0.0026 * 6.2832);
    float3 tape = float3(0.058, 0.064, 0.09) * (0.8 + 0.25 * ribs);
    tape *= 0.55 + 0.45 * smoothstep(0.0, 0.012, depth);   // in the teeth's shadow
    tape += accent * 0.08 * exp(-depth / 0.01) * openHere;
    // A line of stitching where the tape is sewn to the cloth.
    float stitchLine = 1.0 - smoothstep(0.0007, 0.0007 + aa, abs(depth - (kTape - 0.0055)));
    float dash = fract(along / 0.0105);
    float stitch = stitchLine * smoothstep(0.08, 0.18, dash) * (1.0 - smoothstep(0.7, 0.8, dash));
    tape = mix(tape, mix(float3(0.34, 0.37, 0.48), accent, 0.35) * 0.75, stitch);

    float onTape = 1.0 - smoothstep(kTape - aa, kTape + aa, depth);
    float3 cloth = mix(fabric, tape, onTape);
    cloth *= 1.0 - 0.5 * exp(-abs(depth - kTape) / (aa * 1.5 + 0.0008));   // the seam
    cloth *= vignette * (1.0 - 0.3 * u.release);
    h.cloth = float4(cloth * inside, inside);

    // ---- The teeth: every other slot down the chain is this half's.
    float slot = floor(along / kPitch);
    float v = (fract(along / kPitch) - 0.5) * kPitch;
    bool mine = abs(fmod(slot + 4096.0, 2.0) - side) < 0.5;
    float tip = 2.0 * kReach;
    float thick = kPitch * 0.46;
    float center = (tip - kRoot) * 0.5;
    float body = sdRoundBox(float2(across - center, v), float2((tip + kRoot) * 0.5, thick * 0.9), 0.003);
    float head = length(float2(across - (tip - thick), v)) - thick;
    float d = smin(body, head, 0.002);
    float cover = mine ? 1.0 - smoothstep(-aa, aa, d) : 0.0;

    float3 tooth = float3(0.0);
    if (cover > 0.0) {
        float headward = clamp((across - (tip - thick)) / thick, 0.0, 1.0);
        float3 n = normalize(float3(mirror * headward * 0.9, v / thick * 0.85, 1.0));
        float diffuse = max(dot(n, l), 0.0);
        float spec = pow(max(dot(n, hv), 0.0), 40.0);
        float3 base = mix(float3(0.29, 0.31, 0.36), accent, 0.1);
        tooth = base * (0.22 + 0.85 * diffuse) + spec * 0.38;
        // The cup in each head, where the neighbour's head sits.
        float2 cup = float2(across - (tip - thick * 1.15), v);
        tooth *= 1.0 - 0.35 * exp(-dot(cup, cup) / (thick * thick * 0.12));
        tooth *= 0.6 + 0.4 * smoothstep(-0.002, 0.008, across);  // clamped into the tape
        // Light off the loom on the heads that face the gap.
        tooth += accent * 0.18 * openHere * smoothstep(tip - 2.0 * thick, tip, across);
        // Now and then a glint runs down the chain.
        float glintY = fract(t / 6.5) * 1.8 - 0.4;
        tooth += (0.2 + 0.8 * spec) * exp(-abs(along - glintY) * 30.0) * 0.4;
        tooth += accent * exp(-length(p - pointer) * 22.0) * u.pointerStrength * 0.35;
        tooth *= 0.75 + 0.25 * vignette;
    }
    h.teeth = float4(tooth * cover, cover);

    // Into the gap: a tight contact shadow under the teeth, and a broad one.
    float beyond = max(across - tip, 0.0);
    h.shade = (0.5 * exp(-beyond / 0.018) + 0.12 * exp(-beyond / 0.09)) * step(0.0, across);
    return h;
}

// The slider: a rounded body, wider at the top where the two rows go in.
static float sliderShape(float2 q) {
    float k = clamp((q.y + 0.036) / 0.072, 0.0, 1.0);
    return sdRoundBox(q, float2(mix(0.034, 0.024, k), 0.036), 0.012);
}

// The pull tab, hanging from its hinge at the origin: a hole for the lug at
// the top, flaring a little towards the grip.
static float tabBody(float2 q) {
    float k = clamp(q.y / 0.085, 0.0, 1.0);
    return sdRoundBox(q - float2(0.0, 0.0385), float2(mix(0.0125, 0.0185, k), 0.0465), 0.0105);
}

static float tabShape(float2 q) {
    float hole = sdRoundBox(q - float2(0.0, 0.0045), float2(0.0055, 0.0075), 0.004);
    return max(tabBody(q), -hole);
}

// weft's icon, embossed on the tab: one tall tile, a square, two small ones.
static float iconTiles(float2 q) {
    float4 tiles[4] = {
        float4(0.156, 0.156, 0.466, 0.843), float4(0.534, 0.156, 0.843, 0.466),
        float4(0.534, 0.534, 0.653, 0.843), float4(0.723, 0.534, 0.843, 0.843),
    };
    float d = 1e3;
    for (int i = 0; i < 4; i++) {
        float2 lo = tiles[i].xy, hi = tiles[i].zw;
        d = min(d, sdRoundBox(q - (lo + hi) * 0.5, (hi - lo) * 0.5, 0.05));
    }
    return d;
}

// Lit, bevelled metal from a shape's SDF: a flat face that rounds off at the rim.
static float3 brushedMetal(float sd, float2 gradient, float3 base, float env, float3 l, float3 hv,
                    float2x2 toScreen, thread float &spec) {
    float2 g = gradient / max(length(gradient), 1e-5);
    float flat = smoothstep(0.0, 0.009, -sd);
    float3 n = normalize(float3(toScreen * (g * (1.0 - flat) * 1.5), 1.0));
    float diffuse = max(dot(n, l), 0.0);
    spec = pow(max(dot(n, hv), 0.0), 36.0);
    float3 color = base * env * (0.3 + 0.8 * diffuse) + spec * 0.42;
    // A bright line where the bevel turns into the face.
    color += 0.12 * exp(-abs(-sd - 0.009) / 0.0015) * diffuse;
    return color;
}

fragment half4 zipperFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 position = in.position.xy / u.contentScale;
    float scale = 1.0 / max(u.size.y, 1.0);
    float2 p = position * scale;
    float aspect = u.size.x * scale;
    float aa = scale / u.contentScale;   // one pixel
    float c = aspect * 0.5;
    float t = u.time;
    float3 accent = float3(u.accent.rgb);
    float2 pointer = u.pointer * scale;
    float3 l = normalize(kLight);
    float3 hv = normalize(l + float3(0.0, 0.0, 1.0));
    float near = exp(-length(p - pointer) * 18.0) * u.pointerStrength;

    Half left = halfAt(p, 0.0, c, aspect, aa, accent, pointer, u);
    Half right = halfAt(p, 1.0, c, aspect, aa, accent, pointer, u);

    float shade = 1.0 - (1.0 - left.shade) * (1.0 - right.shade);
    float4 color = float4(0.0, 0.0, 0.0, shade * 0.75);
    color = over(color, left.cloth);
    color = over(color, right.cloth);
    color = over(color, left.teeth);
    color = over(color, right.teeth);

    // ---- The slider.
    float2 sq = p - float2(c, u.sliderY);
    float drop = sliderShape(sq - float2(0.004, 0.012));
    color = over(color, float4(0.0, 0.0, 0.0, 0.55 * (1.0 - smoothstep(-0.014, 0.02, drop))));
    float sd = sliderShape(sq);
    float cover = 1.0 - smoothstep(-aa, aa, sd);
    if (cover > 0.0) {
        float e = 0.0015;
        float2 g = float2(sliderShape(sq + float2(e, 0.0)) - sliderShape(sq - float2(e, 0.0)),
                          sliderShape(sq + float2(0.0, e)) - sliderShape(sq - float2(0.0, e)));
        float env = mix(1.0, 0.6, clamp((sq.y + 0.036) / 0.072, 0.0, 1.0));
        env *= 0.95 + 0.07 * hash11(floor(sq.y * 2600.0));   // brushed
        float spec;
        float3 base = mix(float3(0.3, 0.32, 0.37), accent, 0.08);
        float3 body = brushedMetal(sd, g, base, env, l, hv, float2x2(1.0), spec);
        // A raised plate on the face, set off by a groove.
        float plate = sdRoundBox(sq - float2(0.0, -0.005), float2(mix(0.022, 0.015, clamp((sq.y + 0.03) / 0.05, 0.0, 1.0)), 0.023), 0.008);
        body *= 1.0 - 0.45 * exp(-abs(plate) / 0.0012);
        body += (accent * 0.06 + 0.04) * (1.0 - smoothstep(-aa, aa, plate)) * env;
        // The lug the tab hangs from.
        float lug = sdRoundBox(sq - float2(0.0, 0.022), float2(0.009, 0.0045), 0.0035);
        body *= 1.0 - 0.5 * exp(-abs(lug) / 0.0015);
        body += 0.1 * (1.0 - smoothstep(-aa, aa, lug)) * smoothstep(0.026, 0.018, sq.y);
        body += accent * near * 0.25;
        color = over(color, float4(body * cover, cover));
    }

    // ---- The pull tab, swinging on the lug.
    float2 hinge = p - float2(c, u.sliderY + 0.022);
    float cs = cos(u.tabAngle), sn = sin(u.tabAngle);
    float2x2 toTab = float2x2(float2(cs, -sn), float2(sn, cs));    // screen → tab
    float2x2 toScreen = float2x2(float2(cs, sn), float2(-sn, cs)); // tab → screen
    float2 tq = toTab * hinge;
    float tabDrop = tabShape(toTab * (hinge - float2(0.005, 0.012)));
    color = over(color, float4(0.0, 0.0, 0.0, 0.5 * (1.0 - smoothstep(-0.01, 0.018, tabDrop))));
    float td = tabShape(tq);
    float tabCover = 1.0 - smoothstep(-aa, aa, td);
    if (tabCover > 0.0) {
        float e = 0.0012;
        float2 g = float2(tabShape(tq + float2(e, 0.0)) - tabShape(tq - float2(e, 0.0)),
                          tabShape(tq + float2(0.0, e)) - tabShape(tq - float2(0.0, e)));
        float env = mix(1.0, 0.65, clamp(tq.y / 0.085, 0.0, 1.0));
        float spec;
        float3 tab = brushedMetal(td, g, mix(float3(0.3, 0.32, 0.37), accent, 0.08), env, l, hv, toScreen, spec);
        // Enamel, in the accent, below the hole.
        float enamel = max(tabBody(tq) + 0.0042, 0.02 - tq.y);
        float inEnamel = 1.0 - smoothstep(-aa, aa, enamel);
        float fall = clamp((tq.y - 0.02) / 0.063, 0.0, 1.0);
        float3 glaze = mix(accent * 0.78, accent * 0.34, fall);
        glaze += 0.3 * exp(-abs(tq.x + 0.006) / 0.002) * (1.0 - fall);   // gloss
        // The icon, raised out of the enamel.
        float2 iconQ = (tq - float2(0.0, 0.058)) / 0.021 + 0.5;
        float icon = iconTiles(iconQ) * 0.021;
        float iconShadow = iconTiles(iconQ - float2(0.04, 0.06)) * 0.021;
        glaze *= 1.0 - 0.35 * (1.0 - smoothstep(-aa, aa * 2.0, iconShadow));
        glaze = mix(glaze, mix(accent, float3(0.95), 0.6), 1.0 - smoothstep(-aa, aa, icon));
        tab = mix(tab, glaze, inEnamel);
        tab += accent * near * 0.25;
        color = over(color, float4(tab * tabCover, tabCover));
    }

    // Grain against banding, only where something is drawn.
    color.rgb += (hash21(in.position.xy + fract(t)) - 0.5) * 0.01 * color.a;
    color.rgb = clamp(color.rgb, 0.0, color.a);
    return half4(color);
}
"""#
}
