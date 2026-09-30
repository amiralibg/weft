import Foundation

/// Metal source for `LoomView`, compiled when Setup first opens.
///
/// A string rather than a `.metal` file: SwiftPM would need Xcode's Metal
/// Toolchain to build one, a separate download every build machine would have
/// to have. The Metal compiler built into macOS takes the source as it is; the
/// cost is a one-off compile of a few milliseconds.
enum LoomShader {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// The stage behind Setup: a loom seen from the weaver's seat. Warp threads run
// away into the dark; below the fell (the edge of the cloth) they are woven,
// over and under, with an accent-coloured weft. A shuttle flies across on the
// newest row, laying the next pick behind it, and the cloth takes up one row
// when it lands. Each page change beats the reed, which sends a pulse up the
// warp; the pointer plucks the threads under it.
// Coordinates are in "height units": y runs 0…1 down the view, x 0…aspect.

struct Uniforms {
    float2 size;
    float2 pointer;
    float time;
    float beatAge;
    float progress;
    float pointerStrength;
    float contentScale;
    float4 accent;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut loomVertex(uint id [[vertex_id]]) {
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

constant float kSpacing = 1.0 / 92.0;   // warp pitch, at the front
constant float kRow = kSpacing * 0.92;  // weft pitch
constant float kPeriod = 4.6;           // one pass of the shuttle, and its rest

// Threads converge towards the top, where the warp runs off into the distance.
static float depthAt(float y) { return 0.6 + 0.4 * y; }

// How far the shuttle is through the current pass. `travel` is 0…1 across the
// cloth; `takeUp` is 0…1 through the cloth winding down one row afterwards.
static void shuttleState(float t, thread float &pass, thread float &travel, thread float &takeUp) {
    float cycle = t / kPeriod;
    pass = floor(cycle);
    float phase = fract(cycle);
    travel = smoothstep(0.0, 0.58, phase);
    takeUp = smoothstep(0.66, 0.94, phase);
}

// A cylinder in cross-section: 1 on the crown, 0 at the edge, with an
// antialiased rim `aa` wide (both in units of the half-width).
static float cylinder(float d, float aa, thread float &crown) {
    float cover = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, d);
    crown = sqrt(max(0.0, 1.0 - d * d));
    return cover;
}

fragment half4 loomFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 position = in.position.xy / u.contentScale;
    float scale = 1.0 / max(u.size.y, 1.0);
    float2 p = position * scale;
    float aspect = u.size.x * scale;
    float onePoint = scale;
    float t = u.time;
    float3 accent = float3(u.accent.rgb);

    // The fell rises as Setup goes on: the cloth grows with the steps.
    float fell = 0.93 - 0.13 * u.progress;

    // The room: ink, a pool of accent light and a violet one, as the icon.
    float3 ink = float3(0.043, 0.047, 0.07);
    float3 color = mix(float3(0.07, 0.078, 0.12), ink, smoothstep(0.0, 0.9, p.y));
    float2 glowA = float2(aspect * (0.3 + 0.05 * sin(t * 0.11)), 0.26 + 0.04 * cos(t * 0.13));
    float2 glowB = float2(aspect * (0.84 + 0.04 * cos(t * 0.07)), 0.16);
    float poolA = exp(-dot(p - glowA, p - glowA) * 3.4);
    float poolB = exp(-dot(p - glowB, p - glowB) * 4.5);
    color += accent * poolA * 0.12 + float3(0.64, 0.46, 0.97) * poolB * 0.06;

    float pass, travel, takeUp;
    shuttleState(t, pass, travel, takeUp);
    float direction = fmod(pass, 2.0) < 1.0 ? 1.0 : -1.0;
    float margin = aspect * 0.05;
    float shuttleX = direction > 0.0 ? mix(margin, aspect - margin, travel) : mix(aspect - margin, margin, travel);

    // Rows below the fell, counted in content space so the cloth winds down
    // smoothly: row 0 is the one being laid.
    float rowSpace = (p.y - fell) / kRow - takeUp;
    float rowLocal = floor(rowSpace);
    bool inCloth = p.y > fell + takeUp * kRow;

    // Warp space: straight columns once perspective is taken out.
    float depth = depthAt(p.y);
    float center = aspect * 0.5;
    float warpX = center + (p.x - center) / depth;

    // Above the cloth the warp is a string held at the fell: plucked by the
    // pointer, pulsed by the reed, and swaying a little on its own.
    float2 pointer = u.pointer * scale;
    float pointerWarp = center + (pointer.x - center) / depthAt(pointer.y);
    float span = clamp(p.y / fell, 0.0, 1.0);
    float string = sin(3.14159 * span);
    float displacement = 0.0;
    if (!inCloth) {
        float near = exp(-abs(warpX - pointerWarp) * 48.0);
        displacement += u.pointerStrength * near * string * sin(t * 24.0 + warpX * 260.0) * 0.005;
        float above = fell - p.y;
        float front = u.beatAge * 0.5;
        float envelope = exp(-u.beatAge * 1.3) * smoothstep(0.0, 0.08, u.beatAge);
        displacement += sin((above - front) * 70.0) * exp(-abs(above - front) * 10.0) * envelope * 0.0065 * string;
        displacement += sin(t * 0.6 + warpX * 9.0 + p.y * 3.0) * 0.0005 * string;
    }

    float cell = (warpX + displacement) / kSpacing;
    float column = floor(cell);
    float across = fract(cell) - 0.5;
    float aaWarp = onePoint / depth / kSpacing;
    float variation = 0.9 + 0.2 * hash11(column);

    float3 warpColor = float3(0.25, 0.3, 0.47) * variation;
    float3 weftColor = mix(accent, float3(0.95), 0.08);

    // A pick being laid only covers the row behind the shuttle.
    bool laying = rowLocal == 0.0 && takeUp == 0.0;
    bool laid = !laying || (direction > 0.0 ? p.x < shuttleX : p.x > shuttleX);

    if (inCloth && laid) {
        // Plain weave: warp over weft, then under, alternating by row. The row
        // number is global, so the pattern winds down with the cloth.
        float row = pass - rowLocal;
        float along = fract(rowSpace) - 0.5;
        bool warpOnTop = fmod(abs(column + row), 2.0) < 1.0;
        float fade = 0.12 + 0.5 * exp(-(p.y - fell) * 9.0);
        float crown;
        if (warpOnTop) {
            float cover = cylinder(abs(across) / 0.5, aaWarp / 0.5, crown);
            float dip = 0.45 + 0.55 * cos(along * 3.14159 * 0.9);
            float3 top = warpColor * (0.3 + 0.8 * crown) * dip;
            float3 under = weftColor * 0.16;
            color = mix(under, top, cover);
        } else {
            float aaRow = onePoint / kRow;
            float cover = cylinder(abs(along) / 0.5, aaRow / 0.5, crown);
            float dip = 0.45 + 0.55 * cos(across * 3.14159 * 0.9);
            float3 top = weftColor * (0.2 + 0.5 * crown) * dip;
            float3 under = warpColor * 0.18;
            color = mix(under, top, cover);
        }
        // The freshest pick still glows where the shuttle has just been.
        if (rowLocal == 0.0 && laying) {
            float behind = abs(p.x - shuttleX);
            color += accent * exp(-behind * 14.0) * 0.18;
        }
        color *= fade;
        color += accent * poolA * 0.05;
    } else {
        // Open warp: thin, fading into the distance at the top.
        float crown;
        float cover = cylinder(abs(across) / 0.13, aaWarp / 0.13, crown);
        // Faint where the copy sits, clearer as the warp nears the cloth.
        float farFade = pow(smoothstep(0.0, 1.0, p.y / fell), 1.6);
        float near = exp(-abs(warpX - pointerWarp) * 30.0) * u.pointerStrength;
        float3 strandColor = warpColor * (0.45 + 0.6 * crown) * (0.5 + 0.9 * poolA) + accent * near * 0.35;
        color = mix(color, strandColor, cover * (0.1 + 0.4 * farFade));
    }

    // The fell: a hairline of light, bright for a moment after a beat.
    float fellY = fell + takeUp * kRow;
    float beat = exp(-u.beatAge * 2.2) * smoothstep(0.0, 0.05, u.beatAge);
    color += accent * exp(-abs(p.y - fellY) / onePoint * 0.7) * (0.06 + beat * 0.5);

    // The shuttle: a pearl spindle riding the newest row, glowing a little.
    float shuttleY = fell + kRow * (0.5 + takeUp);
    float2 q = p - float2(shuttleX, shuttleY);
    float halfLength = 0.04;
    float halfHeight = 0.008;
    float alongShuttle = clamp(q.x / halfLength, -1.0, 1.0);
    float profile = halfHeight * (1.0 - alongShuttle * alongShuttle);
    float inside = (1.0 - smoothstep(-onePoint, onePoint, abs(q.y) - profile)) * step(abs(q.x), halfLength);
    float2 halo = q / float2(halfLength * 1.6, halfHeight * 5.0);
    color += accent * exp(-dot(halo, halo) * 1.2) * 0.3;
    float2 shadowQ = (q - float2(0.0, 0.006)) / float2(halfLength * 1.2, halfHeight * 2.2);
    color *= 1.0 - exp(-dot(shadowQ, shadowQ) * 2.0) * 0.35;
    float lit = 0.72 + 0.28 * clamp(-q.y / max(profile, 1e-4), -1.0, 1.0);
    float3 pearl = float3(0.93, 0.92, 0.9) * lit;
    // A slot of darker wood down the middle, where the bobbin sits.
    float slot = step(abs(q.x), halfLength * 0.42) * (1.0 - smoothstep(0.0, onePoint * 1.2, abs(q.y) - profile * 0.28));
    pearl = mix(pearl, float3(0.36, 0.3, 0.26), slot * 0.8);
    color = mix(color, pearl, inside);

    // Vignette, a soft shoulder so nothing clips, and grain against banding.
    float2 centered = (p - float2(aspect * 0.5, 0.5)) / float2(aspect, 1.0);
    color *= 1.0 - dot(centered, centered) * 0.75;
    color = 1.0 - exp(-color * 1.15);
    color += (hash21(position + fract(t)) - 0.5) * 0.01;

    return half4(half3(clamp(color, 0.0, 1.0)), 1.0);
}
"""#
}
