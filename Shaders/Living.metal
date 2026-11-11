// Atelier Live Wallpapers. Original fragment shaders; the ones named wallpaper* read the owner's
// own wallpaper image, bound at texture(0) with a full mip chain.
// Build: xcrun -sdk macosx metal Shaders/Living.metal -o default.metallib
#include <metal_stdlib>
using namespace metal;

/// Mirrors LivingUniforms in LiveWallpaper.swift. Keep the order and the padding.
struct Uniforms {
    float2 resolution;
    float2 pointer;   // 0...1, origin top left, already smoothed by a spring
    float time;       // seconds, stops while paused
    float day;        // 0...1 through the local day, use through cos() so midnight never jumps
    float daylight;   // 0 at night, 1 at midday
    float golden;     // peaks around sunrise and sunset
    float presence;   // 1 while the pointer is on this surface
    float opacity;    // master fade, output is premultiplied
    float seed;       // differs per screen
    float contrast;   // 0...1, 0.5 is the shader as designed
    float grain;      // 0...1 film grain over the dither
    float scale;      // 1 as designed, above 1 zooms in
    float dim;        // 0...1, darkens for legibility
    float paletteMix; // 0 keeps the shader's own colour, 1 maps it onto `palette`
    float4 palette[4];// deep, shadow, body, crest. Linear, w unused.
};

struct Varying {
    float4 position [[position]];
    float2 uv;
};

vertex Varying livingVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    Varying out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// MARK: Shared

static inline float hash21(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static inline float2 hash22(float2 p) {
    float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

static inline float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
}

static inline float fbm(float2 p, int octaves) {
    const float2x2 turn = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
    float value = 0.0, amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise(p);
        p = turn * p * 2.03 + 11.7;
        amplitude *= 0.5;
    }
    return value;
}

static inline float aspect(constant Uniforms &u) { return u.resolution.x / u.resolution.y; }

/// The frame the shader paints, zoomed about the centre. The pointer arrives already zoomed.
static inline float2 field(Varying in, constant Uniforms &u) { return (in.uv - 0.5) / u.scale + 0.5; }

static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// The owner's look, applied after the shader: palette, contrast, brightness.
/// Every branch here is on a uniform, so it costs the same for every pixel.
static inline float3 grade(float3 color, constant Uniforms &u, bool mapPalette) {
    if (mapPalette && u.paletteMix > 0.001) {
        float l = luma(color);
        float x = sqrt(saturate(l));   // spread the dark range, where most of the screen lives
        float3 a = u.palette[0].rgb, b = u.palette[1].rgb, c = u.palette[2].rgb, d = u.palette[3].rgb;
        float3 mapped = x < 0.34 ? mix(a, b, x / 0.34) : (x < 0.68 ? mix(b, c, (x - 0.34) / 0.34) : mix(c, d, (x - 0.68) / 0.32));
        // Half of the original light survives, so stars stay stars and crests stay bright.
        mapped *= mix(1.0, (l + 0.004) / (luma(mapped) + 0.004), 0.5);
        mapped = mix(mapped, mapped + color * 0.25, saturate(l * 2.0));
        color = mix(color, mapped, u.paletteMix);
    }
    if (abs(u.contrast - 0.5) > 0.001) {
        float k = exp2((u.contrast - 0.5) * 1.3);          // 0.64 ... 1.57
        color = 0.18 * pow(max(color, 0.0) / 0.18, k);     // pivot at mid grey
        float l = luma(color);
        color = max(mix(float3(l), color, 1.0 + (u.contrast - 0.5) * 0.7), 0.0);
    }
    return color * (1.0 - u.dim * 0.85);
}

/// Gentle shoulder, so highlights roll off instead of clipping.
static inline float3 shoulder(float3 c) { return 1.0 - exp(-c * 1.35); }

/// Triangular dither of one 8-bit step: two decorrelated uniforms summed. Below one step it
/// leaves visible bands on slow gradients; this removes them, and it moves with time so it never
/// reads as a fixed pattern.
static inline float3 tpdf(float2 pixel, float time) {
    float2 j = pixel + fract(time * 0.618) * 97.0;
    float a = fract(52.9829189 * fract(dot(j, float2(0.06711056, 0.00583715))));
    float b = hash21(j * 1.37 + 17.0);
    return float3((a + b - 1.0) / 255.0);
}

/// Vignette, dither against banding on slow gradients, premultiplied output.
/// `mapPalette` false is for shaders that paint with the palette themselves.
static inline float4 finish(float3 color, Varying in, constant Uniforms &u, bool mapPalette = true) {
    color = grade(color, u, mapPalette);
    float2 c = in.uv - 0.5;
    color *= 1.0 - dot(c, c) * 0.55;
    color += tpdf(in.position.xy, u.time);
    if (u.grain > 0.001) {
        // Film grain: fresh every frame, strongest in the mid tones, never on pure black.
        float n = hash21(in.position.xy + fract(u.time * 7.13) * 431.0) - 0.5;
        float body = saturate(luma(color) * 6.0) * (1.0 - saturate(luma(color)) * 0.6);
        color += n * u.grain * 0.075 * (0.3 + body);
    }
    color = saturate(color);
    return float4(color * u.opacity, u.opacity);
}

/// Warm at sunrise and sunset, cool blue at midday, indigo at night.
static inline float3 skyTint(constant Uniforms &u) {
    float3 night = float3(0.10, 0.12, 0.32), noon = float3(0.20, 0.46, 0.66), dusk = float3(0.90, 0.42, 0.26);
    return mix(mix(night, noon, u.daylight), dusk, saturate(u.golden));
}

// MARK: Liquid Light

static inline float liquidHeight(float2 p, float t, thread float2 &flow) {
    float2 q = float2(fbm(p + float2(0.0, t), 3), fbm(p + float2(5.2, 1.3) - t * 0.8, 3));
    flow = float2(fbm(p + 1.9 * q + float2(1.7 + t * 0.7, 9.2), 3),
                  fbm(p + 1.9 * q + float2(8.3, 2.8 - t * 0.6), 3));
    return fbm(p + 1.7 * flow, 4);
}

/// Three stops for the hour: the depths, the body of the light, the crest.
static inline float3 liquidRamp(float x, constant Uniforms &u) {
    float3 lowN = float3(0.018, 0.012, 0.085), midN = float3(0.20, 0.12, 0.74), topN = float3(0.26, 0.84, 0.96);
    float3 lowD = float3(0.010, 0.060, 0.115), midD = float3(0.03, 0.42, 0.62), topD = float3(0.72, 0.96, 0.90);
    float3 lowG = float3(0.085, 0.014, 0.060), midG = float3(0.80, 0.16, 0.30), topG = float3(1.00, 0.70, 0.38);
    float gold = saturate(u.golden);
    float3 low = mix(mix(lowN, lowD, u.daylight), lowG, gold);
    float3 middle = mix(mix(midN, midD, u.daylight), midG, gold);
    float3 top = mix(mix(topN, topD, u.daylight), topG, gold);
    return x < 0.55 ? mix(low, middle, smoothstep(0.0, 0.55, x)) : mix(middle, top, smoothstep(0.55, 1.0, x));
}

fragment float4 liquidLightFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    const float zoom = 1.12;
    float2 p = field(in, u) * float2(a, 1.0) * zoom + u.seed;
    float2 m = u.pointer * float2(a, 1.0) * zoom + u.seed;
    float2 d = p - m;
    float near = exp(-dot(d, d) * 3.2) * u.presence;
    p -= d * near * 0.26;   // the surface leans toward the pointer

    float t = u.time * 0.034;
    float2 flow;
    float h = liquidHeight(p, t, flow);

    float2 slope = float2(dfdx(h), dfdy(h)) * u.resolution.y * 0.13;
    float3 n = normalize(float3(-slope, 1.0));
    float3 toLight = normalize(float3(mix(float2(0.30, -0.60), -d * 1.5, u.presence), 0.9));
    float3 halfway = normalize(toLight + float3(0, 0, 1));
    float spec = pow(max(dot(n, halfway), 0.0), 90.0);
    float sheen = pow(1.0 - n.z, 1.6);

    // The film: a slow standing wave along the height, sharpened so most of the screen stays deep.
    float wave = 0.5 + 0.5 * cos(6.2832 * (h * 3.9 + length(flow) * 1.5 + t * 0.5));
    float light = pow(wave, 1.7) * smoothstep(0.24, 0.56, h) * (0.62 + 0.38 * smoothstep(0.42, 0.70, h));
    float3 color = liquidRamp(light, u);

    float3 film = 0.5 + 0.5 * cos(6.2832 * (h * 5.0 + float3(0.0, 0.33, 0.62)));
    color += sheen * mix(liquidRamp(0.8, u), film, 0.40) * 1.25;
    color += spec * (0.42 + 1.2 * near) * (liquidRamp(1.0, u) * 0.5 + 0.5);
    color += near * liquidRamp(0.6, u) * light * 0.34;
    return finish(shoulder(color), in, u);
}

// MARK: Nebula

static inline float3 starField(float2 p, float scale, float time, float seed) {
    float2 g = p * scale + seed;
    float2 id = floor(g), f = fract(g) - 0.5;
    float2 r = hash22(id);
    float size = 0.015 + 0.05 * r.x * r.x * r.x;
    float presence = step(0.72, hash21(id + 3.1));
    float2 o = (r - 0.5) * 0.7;
    float d = length(f - o);
    float glow = smoothstep(size * 3.0, 0.0, d) * 0.45 + smoothstep(size, size * 0.3, d);
    float twinkle = 0.75 + 0.25 * sin(time * (0.5 + r.y * 1.6) + r.x * 40.0);
    float3 tone = mix(float3(0.72, 0.82, 1.0), float3(1.0, 0.86, 0.72), r.y);
    return tone * glow * twinkle * presence;
}

fragment float4 nebulaFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 p = (field(in, u) - 0.5) * float2(a, 1.0);
    float2 lean = (u.pointer - 0.5) * u.presence;   // depth: near layers shift further

    float t = u.time * 0.012;
    float2 cloud = p * 1.7 + lean * 0.05 + u.seed;
    float2 warp = float2(fbm(cloud + float2(t, -t * 0.6), 4), fbm(cloud + float2(4.1 - t * 0.7, 2.7), 4));
    float2 warped = cloud + warp * 1.05;

    float gas = fbm(warped + float2(0.0, t), 5);
    float veil = fbm(warped * 1.7 + float2(3.3, t * 0.7), 4);
    float ridge = 1.0 - abs(2.0 * fbm(warped * 1.25 + 7.2, 5) - 1.0);
    float grain = fbm(warped * 4.6 - t, 4);
    float dust = smoothstep(0.40, 0.66, fbm(cloud * 2.6 + warp * 1.4 + 9.0, 5));

    float density = smoothstep(0.42, 0.78, gas + (grain - 0.5) * 0.30);
    density *= density;

    float gold = saturate(u.golden);
    float3 cold = mix(float3(0.02, 0.17, 0.42), float3(0.04, 0.40, 0.52), veil);
    cold = mix(cold, float3(0.13, 0.34, 0.68), u.daylight * 0.8);
    float3 hot = mix(float3(0.46, 0.05, 0.40), float3(0.92, 0.26, 0.34), ridge * ridge);
    hot = mix(hot, float3(0.98, 0.46, 0.22), gold * 0.55);
    float3 gasColor = mix(cold, hot, smoothstep(0.40, 0.60, veil + gold * 0.08 - u.daylight * 0.05));

    float2 m = (u.pointer - 0.5) * float2(a, 1.0);
    float2 d = p - m;
    float lamp = exp(-dot(d, d) * 6.0) * u.presence;

    float3 color = skyTint(u) * 0.022 + float3(0.003, 0.004, 0.010);
    color += starField(p + lean * 0.015, 26.0, u.time, u.seed) * (1.0 - density);
    color += starField(p + lean * 0.03, 58.0, u.time, u.seed + 4.0) * 0.5 * (1.0 - density);
    color += gasColor * density * (0.55 + ridge * ridge * 1.15);
    color *= 1.0 - dust * 0.82;
    color += gasColor * (density * 0.9 + 0.05) * lamp * 1.0;      // the pointer lights the gas it is near
    color += starField(p + lean * 0.07, 11.0, u.time, u.seed + 9.0) * 1.1;
    return finish(shoulder(color), in, u);
}

// MARK: Aurora Silk

fragment float4 auroraSilkFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float x = uv.x * a + u.seed;
    float mx = u.pointer.x * a + u.seed;
    float t = u.time * 0.05;
    float gold = saturate(u.golden);

    float3 high = mix(float3(0.010, 0.018, 0.050), float3(0.035, 0.09, 0.20), u.daylight);
    float3 low = mix(float3(0.022, 0.055, 0.10), float3(0.11, 0.21, 0.31), u.daylight);
    low = mix(low, float3(0.60, 0.22, 0.25), gold * 0.72);
    high = mix(high, float3(0.09, 0.05, 0.17), gold * 0.6);
    float3 color = mix(high, low, pow(uv.y, 2.6));
    color += starField(uv * float2(a, 1.0), 44.0, u.time, u.seed) * 0.7 * (1.0 - u.daylight * 0.8) * (1.0 - uv.y);

    float3 silk = float3(0.0);
    for (int i = 0; i < 4; i++) {
        float k = float(i);
        float depth = 1.0 - k * 0.17;
        float drift = t * (1.0 + k * 0.22);
        float curve = 0.66 - k * 0.055
            + 0.11 * sin(x * (0.78 + k * 0.31) + drift * 2.1 + k * 2.4)
            + 0.05 * sin(x * (2.3 - k * 0.37) - drift * 1.4 + k * 5.1)
            + 0.20 * (noise(float2(x * 0.62 - drift, k * 7.3)) - 0.5);
        float bend = exp(-pow(x - mx, 2.0) * 3.2) * u.presence;
        curve += bend * (u.pointer.y - curve) * 0.26;   // the fabric reaches for the pointer

        // Folds slide along the ribbon, like cloth seen edge on.
        float across = x * (4.2 + k * 1.9) + 2.4 * sin(x * 1.05 + drift * 3.0 + k)
            + 2.2 * noise(float2(x * 1.2 + drift, drift * 0.5 + k * 3.0));
        float fold = 0.28 + 0.72 * pow(abs(sin(across)), 2.2);
        float rays = noise(float2(x * 21.0 + k * 5.0, drift * 2.6));
        rays = 0.30 + 0.70 * rays * rays + 0.34 * noise(float2(x * 57.0, k + drift * 3.0));

        float dy = uv.y - curve;
        float height = 0.50 - k * 0.05;
        float climb = saturate(-dy / height);
        float reach = dy < 0.0 ? pow(1.0 - climb, 2.6) : exp(-dy * 44.0);
        float edge = exp(-abs(dy) * 42.0);

        float3 tone = mix(float3(0.08, 1.00, 0.58), float3(0.10, 0.62, 1.0), smoothstep(0.08, 0.50, climb));
        tone = mix(tone, float3(0.68, 0.20, 1.0), smoothstep(0.40, 0.92, climb));
        tone = mix(tone, float3(1.0, 0.30, 0.52), gold * 0.42);
        silk += tone * reach * fold * rays * depth * 0.62 + tone * edge * fold * depth * 0.10;
    }
    color += silk * (1.0 - u.daylight * 0.38);

    // Two ridges. The far one catches a little of the light above it.
    float far = 0.815 + 0.085 * (fbm(float2(x * 1.25 + 4.0, 3.1), 4) - 0.5) + 0.05 * (abs(sin(x * 1.7 + 1.0)) - 0.5);
    float near = 0.905 + 0.10 * (fbm(float2(x * 1.9, 7.7), 5) - 0.5);
    float3 glow = silk * 0.05 + low * 0.14;
    color = mix(color, glow + float3(0.006, 0.009, 0.016), smoothstep(far, far + 0.002, uv.y));
    color = mix(color, low * 0.05 + float3(0.003, 0.004, 0.008), smoothstep(near, near + 0.002, uv.y));
    return finish(shoulder(color), in, u);
}

// MARK: Topography

fragment float4 topographyFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 p = field(in, u) * float2(a, 1.0);
    float2 m = u.pointer * float2(a, 1.0);
    float2 d = p - m;
    float near = exp(-dot(d, d) * 7.0) * u.presence;

    float t = u.time * 0.008;
    float2 q = p * 1.5 + u.seed;
    float h = fbm(q + float2(t, -t * 0.7) + 0.55 * fbm(q * 0.8 - t, 2), 4);
    h += near * 0.22;   // a hill rises under the pointer

    const float levels = 34.0;
    float v = h * levels;
    float width = fwidth(v);
    float f = abs(fract(v - 0.5) - 0.5);
    float line = 1.0 - smoothstep(0.0, 1.25 * width, f);
    float band = fract(floor(v + 0.5) / 5.0 + 0.001);
    float major = step(band, 0.1);
    float bold = (1.0 - smoothstep(0.35 * width, 1.9 * width, f)) * major;

    float3 sea = mix(float3(0.030, 0.050, 0.095), float3(0.11, 0.19, 0.24), u.daylight);
    float3 peak = mix(float3(0.075, 0.12, 0.20), float3(0.30, 0.42, 0.42), u.daylight);
    float3 ink = mix(float3(0.42, 0.78, 0.92), float3(0.90, 0.97, 0.93), u.daylight);
    sea = mix(sea, float3(0.17, 0.085, 0.13), saturate(u.golden) * 0.7);
    peak = mix(peak, float3(0.45, 0.22, 0.20), saturate(u.golden) * 0.7);
    ink = mix(ink, float3(1.0, 0.74, 0.50), saturate(u.golden) * 0.8);

    float elevation = smoothstep(0.26, 0.72, h);
    float3 color = mix(sea, peak, elevation);

    // Hill shading from the northwest, faint, so the map has relief.
    float2 slope = float2(dfdx(h), dfdy(h)) * u.resolution.y;
    color *= 1.0 + clamp(dot(slope, float2(-0.7, -0.7)) * 0.16, -0.32, 0.32);

    color = mix(color, ink, line * (0.20 + 0.32 * near));
    color = mix(color, ink, bold * (0.56 + 0.34 * near));

    // Survey crosses at a fixed spacing, the only thing that does not move.
    float2 g = abs(fract(p * 8.0 + 0.5) - 0.5) / 8.0;
    float tick = (1.0 - smoothstep(0.0003, 0.0012, min(g.x, g.y))) * step(max(g.x, g.y), 0.0052);
    color = mix(color, ink, tick * 0.34);
    return finish(color, in, u);
}

// MARK: Glass Rain

/// The world outside the pane, lit by the hour. `focus` runs from far out of focus to nearly sharp.
static inline float3 beyondGlass(float2 q, float2 uv, float focus, constant Uniforms &u) {
    float gold = saturate(u.golden);
    float3 top = mix(float3(0.020, 0.030, 0.075), float3(0.27, 0.36, 0.46), u.daylight);
    float3 bottom = mix(float3(0.060, 0.045, 0.090), float3(0.46, 0.53, 0.56), u.daylight);
    top = mix(top, float3(0.20, 0.11, 0.24), gold * 0.85);
    bottom = mix(bottom, float3(0.86, 0.40, 0.20), gold * 0.85);
    float3 color = mix(top, bottom, smoothstep(0.05, 1.0, uv.y));

    float night = 1.0 - u.daylight * 0.74;
    float3 lights = float3(0.0);
    for (int sheet = 0; sheet < 2; sheet++) {
        float2 g = q * (sheet == 0 ? 7.0 : 12.0) + float2(u.seed + float(sheet) * 3.7, float(sheet) * 1.3);
        float2 id = floor(g), f = fract(g);
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 cell = id + float2(x, y);
                float2 r = hash22(cell);
                float on = step(0.45, hash21(cell + 7.7));
                float2 c = float2(x, y) + r;
                float radius = (0.30 + 0.40 * hash21(cell + 2.2)) * (1.0 - 0.72 * focus);
                float disc = 1.0 - smoothstep(radius * (0.72 + 0.2 * focus), radius, length(f - c));
                float3 tone = mix(float3(1.0, 0.70, 0.36), float3(0.42, 0.68, 1.0), step(0.74, r.y));
                tone = mix(tone, float3(1.0, 0.27, 0.24), step(0.90, r.x));
                lights += tone * disc * on;
            }
        }
    }
    float lower = smoothstep(0.12, 0.80, uv.y);
    return color + lights * (0.17 + 0.5 * focus) * night * lower;
}

struct DropSheet {
    float2 normal;   // direction out of the drop's centre, length 0 to 1
    float lens;      // inside a drop or bead
    float wet;       // the clear path left behind
};

/// Drops sliding down the pane. All distances are in screen heights, so drops stay round.
static inline DropSheet runningDrops(float2 q, float time, float scale, float seed) {
    float2 cellSize = float2(0.17, 0.62) * scale;
    float column = floor(q.x / cellSize.x);
    float offset = hash21(float2(column, seed));
    float y = q.y / cellSize.y + offset * 9.0 - time * (0.022 + offset * 0.03);
    float row = floor(y);
    float2 local = (float2(fract(q.x / cellSize.x), fract(y)) - 0.5) * cellSize;
    float r = hash21(float2(column, row) + seed);

    // Drops hesitate, then run.
    float life = fract(time * (0.040 + r * 0.05) + r * 13.0);
    float run = life * life * (3.0 - 2.0 * life);
    run = mix(run, floor(run * 4.0 + 0.5) / 4.0, 0.42);
    float headY = cellSize.y * (run * 0.74 - 0.37);
    float path = cellSize.x * ((r - 0.5) * 0.46 + 0.05 * sin(local.y * 26.0 + r * 40.0));

    DropSheet sheet;
    float2 d = float2(local.x - path, local.y - headY);
    float radius = (0.013 + 0.015 * r) * scale;
    float2 shape = d / radius * float2(1.0, d.y < 0.0 ? 0.62 : 1.0);   // a pear, tail upward
    float dist = length(shape);
    float head = 1.0 - smoothstep(0.86, 1.0, dist);
    sheet.normal = shape * head;
    sheet.lens = head;

    float above = headY - local.y;
    float reach = cellSize.y * 0.52;
    float along = saturate(above / reach);
    sheet.wet = (1.0 - smoothstep(radius * 0.4, radius * 1.1, abs(local.x - path)))
        * smoothstep(0.0, 0.02, above) * (1.0 - along);

    float pitch = 0.030 * scale;
    float beadRow = floor(local.y / pitch);
    float beadSeed = hash21(float2(column + beadRow * 0.37, row + seed));
    float2 b = float2(local.x - path - (beadSeed - 0.5) * radius * 0.7, (fract(local.y / pitch) - 0.5) * pitch);
    float beadSize = radius * (0.22 + 0.34 * beadSeed) * (1.0 - along * 0.7);
    float bead = (1.0 - smoothstep(0.8, 1.0, length(b) / beadSize)) * step(0.34, beadSeed)
        * step(0.012, above) * step(along, 0.97);
    sheet.normal += b / beadSize * bead;
    sheet.lens = max(sheet.lens, bead);
    return sheet;
}

/// Still condensation, swelling and drying.
static inline DropSheet mist(float2 q, float time, float cells) {
    float2 st = q * cells;
    float2 id = floor(st);
    float2 r = hash22(id);
    float2 cell = fract(st) - 0.5 - (r - 0.5) * 0.55;
    float life = fract(time * 0.035 + r.x * 7.0);
    float size = (0.12 + 0.28 * r.y) * smoothstep(0.0, 0.22, life) * smoothstep(1.0, 0.72, life) * step(0.28, r.y);
    float dist = length(cell) / max(size, 0.001);
    float drop = (1.0 - smoothstep(0.8, 1.0, dist)) * step(0.001, size);
    DropSheet sheet;
    sheet.normal = cell / max(size, 0.001) * drop;
    sheet.lens = drop;
    sheet.wet = 0.0;
    return sheet;
}

fragment float4 glassRainFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 q = uv * float2(a, 1.0);
    float2 d = q - u.pointer * float2(a, 1.0);
    float clear = exp(-dot(d, d) * 15.0) * u.presence;   // a warm hand wipes the pane

    DropSheet large = runningDrops(q, u.time, 1.0, 1.0 + u.seed);
    DropSheet small = runningDrops(q + 3.1, u.time * 1.2, 0.62, 5.0 + u.seed);
    DropSheet fine = mist(q, u.time, 46.0);
    DropSheet finer = mist(q + 0.37, u.time * 0.8, 92.0);

    float2 normal = large.normal + small.normal * (1.0 - large.lens);
    float lens = max(large.lens, small.lens);
    float keep = 1.0 - clear;
    float mistLens = max(fine.lens, finer.lens) * (1.0 - lens) * saturate(1.0 - large.wet - small.wet) * keep;
    normal += (fine.normal + finer.normal) * mistLens;
    lens = max(lens, mistLens);

    // A drop is a tiny fisheye: it shows the whole world upside down.
    float2 look = uv - normal * 0.17;
    look = clamp(look, 0.0, 1.0);
    float wet = saturate(max(large.wet, small.wet) + clear * 1.1);

    float3 blurred = beyondGlass(q, uv, 0.0, u);
    float3 color;
    float3 frosted = mix(blurred, skyTint(u) * 0.5 + 0.13, 0.34 + 0.05 * u.daylight);
    float grain = fbm(q * 170.0, 2);
    frosted += (grain - 0.5) * 0.018;
    if (wet > 0.002) color = mix(frosted, beyondGlass(q, uv, wet * 0.6, u), wet);
    else color = frosted;

    if (lens > 0.001) {
        float3 inside = beyondGlass(look * float2(a, 1.0), look, 0.85, u);
        float3 n = normalize(float3(normal, 0.75));
        float glint = pow(max(dot(n, normalize(float3(-0.35, -0.68, 0.62))), 0.0), 34.0);
        float rim = smoothstep(0.55, 1.0, length(normal));
        inside = inside * (1.0 - rim * 0.55) + glint * 0.72;
        color = mix(color, inside, lens);
    }
    color += clear * clear * skyTint(u) * 0.03;
    return finish(color, in, u);
}


// MARK: Gradient Mesh

/// Five colours for the hour. Blended in a square-root space so the edges between them stay luminous, never muddy.
static inline float3 meshStop(int i, constant Uniforms &u) {
    const float3 night[5] = { float3(0.030, 0.030, 0.220), float3(0.480, 0.120, 0.820), float3(0.000, 0.500, 0.620),
                              float3(0.860, 0.100, 0.460), float3(0.060, 0.160, 0.560) };
    const float3 noon[5]  = { float3(0.300, 0.620, 0.950), float3(0.450, 0.880, 0.780), float3(0.660, 0.580, 0.980),
                              float3(1.000, 0.700, 0.550), float3(0.100, 0.420, 0.860) };
    const float3 dusk[5]  = { float3(1.000, 0.550, 0.200), float3(0.950, 0.300, 0.450), float3(0.400, 0.120, 0.450),
                              float3(1.000, 0.750, 0.450), float3(0.700, 0.120, 0.220) };
    return mix(mix(night[i], noon[i], u.daylight), dusk[i], saturate(u.golden));
}

/// With a palette, the mesh paints with its stops directly: a gradient map would flatten it.
static inline float3 meshPaletteStop(int i, constant Uniforms &u) {
    float3 p0 = u.palette[0].rgb, p1 = u.palette[1].rgb, p2 = u.palette[2].rgb, p3 = u.palette[3].rgb;
    switch (i) {
    case 0: return p2;
    case 1: return p1;
    case 2: return mix(p2, p3, 0.55);
    case 3: return mix(p1, p2, 0.5);
    default: return mix(p0, p1, 0.7);
    }
}

fragment float4 gradientMeshFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 p = (field(in, u) - 0.5) * float2(a, 1.0);
    float t = u.time * 0.045;
    // A slow warp, so the field folds instead of sliding.
    float2 w = float2(noise(p * 1.25 + float2(t, u.seed)), noise(p * 1.25 + float2(5.2 - t, 1.7 + u.seed))) - 0.5;
    p += w * 0.42;
    float2 m = (u.pointer - 0.5) * float2(a, 1.0);
    float2 dm = p - m;
    float near = exp(-dot(dm, dm) * 5.0) * u.presence;
    p += dm * near * 0.35;   // colour parts around the pointer like a fingertip in paint

    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < 5; i++) {
        float k = float(i);
        float2 c = float2(sin(t * (0.61 + k * 0.13) + k * 1.9 + u.seed), cos(t * (0.47 + k * 0.11) + k * 2.7)) * float2(a * 0.48, 0.46);
        float2 d = p - c;
        float weight = exp(-dot(d, d) * 5.5) + 0.0002;
        sum += sqrt(mix(meshStop(i, u), meshPaletteStop(i, u), u.paletteMix)) * weight;
        total += weight;
    }
    float3 color = sum / total;
    color *= color;
    // A breath of light where the colours meet, the satin of the real thing.
    float sheen = noise(p * 0.9 + float2(-t * 0.6, t * 0.4));
    color *= 0.80 + 0.40 * smoothstep(0.20, 0.85, sheen);
    color += near * 0.06 * sqrt(color);
    return finish(color, in, u, false);
}

// MARK: Silk Waves

/// Folds of a draped cloth: one phase, bent by three slow waves. The gradient is analytic, so no extra samples.
static inline float silkPhase(float2 p, float t, thread float2 &grad) {
    float a1 = p.x * 1.10 + p.y * 0.30 + t, a2 = p.x * 2.10 - p.y * 0.70 - t * 0.8, a3 = p.x * 3.70 + p.y * 1.30 + t * 1.2;
    float f = p.y * 4.6 + 2.10 * sin(a1) + 1.10 * sin(a2) + 0.40 * sin(a3);
    grad = float2(2.10 * 1.10 * cos(a1) + 1.10 * 2.10 * cos(a2) + 0.40 * 3.70 * cos(a3),
                  4.6 + 2.10 * 0.30 * cos(a1) - 1.10 * 0.70 * cos(a2) + 0.40 * 1.30 * cos(a3));
    return f;
}

fragment float4 silkWavesFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 p = uv * float2(a, 1.0) * 1.7 + u.seed;
    float2 m = u.pointer * float2(a, 1.0) * 1.7 + u.seed;
    float2 dm = p - m;
    float t = u.time * 0.09;

    float2 g;
    float f = silkPhase(p, t, g);
    // The cloth lifts under the hand: a soft swell added to the folds' normal, never to their phase,
    // so the folds bend over it instead of pinching to a point.
    float pull = exp(-dot(dm, dm) * 1.4) * u.presence;

    // Each fold is a soft ridge with a sharper crest, as silk hangs.
    float s = sin(f), c = cos(f);
    float h = s * 0.5 + 0.18 * sin(2.0 * f + 0.6);
    float dh = (c * 0.5 + 0.36 * cos(2.0 * f + 0.6)) * 0.20;
    float3 n = normalize(float3(-g * dh + dm * pull * 1.3, 1.0));

    // The light swings toward the pointer. Bounded, not normalised, so it stays smooth right under it.
    float2 lean = mix(float2(-0.35, -0.75), -dm / (length(dm) + 0.8), u.presence * 0.5);
    float3 toLight = normalize(float3(lean, 0.55));
    float diffuse = saturate(dot(n, toLight));
    float3 halfway = normalize(toLight + float3(0, 0, 1));
    float spec = pow(saturate(dot(n, halfway)), 48.0);
    float sheen = pow(saturate(1.0 - n.z), 1.4);   // silk glows at grazing angles

    float gold = saturate(u.golden);
    float3 deep = mix(mix(float3(0.004, 0.006, 0.026), float3(0.040, 0.050, 0.080), u.daylight), float3(0.045, 0.010, 0.018), gold);
    float3 body = mix(mix(float3(0.070, 0.080, 0.360), float3(0.360, 0.430, 0.580), u.daylight), float3(0.560, 0.160, 0.140), gold);
    float3 crest = mix(mix(float3(0.560, 0.640, 1.000), float3(0.950, 0.960, 0.990), u.daylight), float3(1.000, 0.780, 0.580), gold);

    // A wide pool of light across the screen, so the cloth has a lit side and a side in shadow.
    float pool = smoothstep(1.35, 0.0, length((uv - float2(0.30, 0.28)) * float2(a * 0.6, 1.0)));
    float x = diffuse * (0.25 + 0.75 * pool) * (0.75 + 0.25 * h);
    float3 color = mix(deep, body, smoothstep(0.02, 0.70, x));
    color = mix(color, crest, smoothstep(0.66, 1.0, x) * 0.6);
    color += sheen * body * 0.9 * (0.3 + pool);
    color += spec * crest * (0.25 + 0.75 * pool);
    return finish(shoulder(color * 1.1), in, u);
}

// MARK: Starfield

/// One sheet of stars, in cells. `z` is depth: 0 far away, 1 passing the viewer.
static inline float3 starSheet(float2 q, float seed, float z) {
    float2 id = floor(q), f = fract(q) - 0.5;
    float2 r = hash22(id + seed);
    float on = step(0.72, hash21(id + seed * 1.7 + 3.1));
    float2 o = (r - 0.5) * 0.5;
    float2 d = f - o;
    float d2 = dot(d, d);
    float size = 0.0012 + 0.0035 * r.x * r.x * r.x;
    float core = exp(-d2 / size);
    // The halo must end inside its cell, or the cell's square edge shows.
    float halo = exp(-d2 / (size * 6.0)) * 0.20 * z * smoothstep(0.25, 0.04, d2);
    float3 tone = r.y < 0.33 ? float3(0.70, 0.80, 1.00) : (r.y < 0.80 ? float3(1.00, 0.97, 0.92) : float3(1.00, 0.78, 0.56));
    return tone * (core + halo) * on;
}

fragment float4 starfieldFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 p = (field(in, u) - 0.5) * float2(a, 1.0);
    float2 lean = (u.pointer - 0.5) * u.presence;
    float gold = saturate(u.golden);

    // The galaxy's plane, a band across the sky with dark lanes of dust.
    float2 axis = normalize(float2(0.82, -0.57));
    float across = dot(p + lean * 0.02, float2(-axis.y, axis.x));
    float2 sky = p * 1.6 + lean * 0.03 + u.seed;
    float cloud = fbm(sky + float2(u.time * 0.003, 0.0), 4);
    float band = exp(-across * across * 5.0) * smoothstep(0.25, 0.85, cloud);
    float core = exp(-across * across * 30.0) * cloud;
    float lanes = smoothstep(0.42, 0.68, fbm(sky * 2.3 + 4.0, 3)) * exp(-across * across * 14.0);
    float3 bandTone = mix(mix(float3(0.20, 0.16, 0.40), float3(0.22, 0.34, 0.55), u.daylight), float3(0.52, 0.24, 0.26), gold);
    float3 coreTone = mix(float3(0.95, 0.80, 0.62), float3(1.0, 0.62, 0.42), gold);
    float3 color = mix(float3(0.002, 0.003, 0.010), skyTint(u) * 0.05, 0.5)
        + (bandTone * band * 0.75 + coreTone * core * 0.30) * (1.0 - lanes * 0.88);

    // Five sheets drift toward you and are replaced at the back. Near ones shift further with the pointer.
    float t = u.time * 0.012;
    for (int i = 0; i < 5; i++) {
        float k = float(i) / 5.0 + t;
        float z = fract(k);
        float seed = floor(k) * 7.31 + float(i) * 13.7 + u.seed;
        float scale = mix(34.0, 4.0, z * z);
        float fade = smoothstep(0.0, 0.3, z) * smoothstep(1.0, 0.78, z);
        float2 q = (p + lean * z * 0.06) * scale + float2(seed * 3.1, seed * 1.7);
        float twinkle = 0.78 + 0.22 * sin(u.time * (1.1 + float(i) * 0.37) + seed);
        color += starSheet(q, seed, z) * fade * twinkle * (0.55 + 0.9 * z) * (1.0 + band * 0.6);
    }
    // A faint dusting of distant stars in the band itself.
    color += starSheet(p * 130.0 + u.seed, u.seed + 1.0, 0.0) * 0.45 * (0.1 + band * 1.4);
    return finish(shoulder(color), in, u);
}

// MARK: Retro Horizon

fragment float4 retroHorizonFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 lean = (u.pointer - 0.5) * u.presence;
    float x = (uv.x - 0.5) * a - lean.x * 0.08;
    float horizon = 0.60 + lean.y * 0.03;
    float gold = saturate(u.golden);
    float day = u.daylight;

    float3 top = mix(mix(float3(0.012, 0.006, 0.050), float3(0.200, 0.360, 0.700), day), float3(0.120, 0.030, 0.180), gold);
    float3 low = mix(mix(float3(0.560, 0.070, 0.420), float3(1.000, 0.680, 0.780), day), float3(1.000, 0.420, 0.220), gold);
    float3 neon = mix(mix(float3(1.000, 0.180, 0.760), float3(0.980, 0.300, 0.700), day), float3(1.000, 0.360, 0.420), gold);
    float3 cyan = mix(float3(0.180, 0.900, 1.000), float3(1.000, 0.900, 0.500), gold * 0.6);

    float3 color;
    if (uv.y < horizon) {
        float h = saturate((horizon - uv.y) / horizon);
        color = mix(low, top, pow(h, 0.55));
        color += starField(float2(x, uv.y), 70.0, u.time, u.seed) * (1.0 - day * 0.9) * smoothstep(0.15, 0.6, h);

        // The sun: a gradient disc, its lower half cut by bands that drift down into the horizon.
        float2 sc = float2(x, uv.y) - float2(0.0, horizon - 0.16);
        float r = length(sc);
        float radius = 0.21;
        float3 sunTone = mix(float3(1.6, 1.25, 0.40), float3(1.5, 0.28, 0.70), saturate(sc.y / radius * 0.5 + 0.5));
        float below = saturate(sc.y / radius);
        float bands = fract(uv.y * 30.0 - u.time * 0.05);
        float cut = step(bands, below * 0.62) * step(0.0, sc.y);
        float disc = smoothstep(radius, radius - 0.0025, r) * (1.0 - cut);
        color = mix(color, sunTone, disc);
        color += sunTone * exp(-max(r - radius, 0.0) * 9.0) * 0.32 * (1.0 - disc);

        // Two ranges of mountains, the near one rimmed in neon.
        float far = horizon - 0.035 - 0.07 * fbm(float2(x * 2.2 + u.seed, 1.3), 4) * smoothstep(0.05, 0.6, abs(x));
        float ridge = 1.0 - abs(2.0 * fbm(float2(x * 1.6 + 7.0 + u.seed, 5.1), 4) - 1.0);
        float near = horizon - 0.008 - 0.13 * ridge * ridge * smoothstep(0.18, 0.95, abs(x));
        color = mix(color, mix(top, low, 0.25) * 0.55, smoothstep(far, far + 0.002, uv.y));
        float edge = exp(-abs(uv.y - near) * 420.0);
        color = mix(color, top * 0.35, smoothstep(near, near + 0.002, uv.y));
        color += neon * edge * 0.6 * smoothstep(near - 0.004, near, uv.y);
    } else {
        // The floor: a grid in perspective, rolling toward you.
        float dy = max(uv.y - horizon, 0.0005);
        float z = 0.16 / dy;
        float gx = x * z * 1.6;
        float gz = z + u.time * 0.45;
        float wx = fwidth(gx), wz = fwidth(gz);
        float lx = exp(-abs(fract(gx + 0.5) - 0.5) / max(wx, 0.0001) * 0.9);
        float lz = exp(-abs(fract(gz + 0.5) - 0.5) / max(wz, 0.0001) * 0.9);
        float far = saturate(1.0 - z * 0.035);              // fades into the haze
        float dense = saturate(1.0 - max(wx, wz) * 1.8);   // where lines would alias, they become haze
        float2 dm = float2(x, uv.y) - float2((u.pointer.x - 0.5) * a, u.pointer.y);
        float touch = exp(-dot(dm, dm) * 18.0) * u.presence;
        float lines = max(lx, lz) * dense * far * (1.0 + touch * 1.6);
        float3 ground = mix(float3(0.010, 0.000, 0.030), low * 0.10, day * 0.6 + gold * 0.3);
        color = ground + neon * lines * 0.9 + low * 0.22 * exp(-dy * 22.0);
        // The sun's reflection, a soft streak below it.
        color += mix(float3(1.0, 0.4, 0.5), low, 0.5) * exp(-x * x * 40.0) * exp(-dy * 9.0) * 0.18;
    }
    color += cyan * exp(-abs(uv.y - horizon) * 260.0) * 0.55;
    return finish(shoulder(color), in, u);
}

// =====================================================================================
// MARK: - Second gallery
// Each one is a single pass with no state: everything is a function of position and time.
// Budget: under 1 ms on the GPU at the desktop's render scale (see `renderScale`).
// =====================================================================================


// MARK: Ocean Caustics

/// Light focused by a moving water surface onto the floor below. Five folds of a trig flow,
/// each one sharper than the last; the bright network is where the folds agree.
static inline float caustic(float2 p, float t) {
    float2 i = p;
    float c = 1.0;
    const float strength = 0.0065;
    for (int n = 0; n < 5; n++) {
        float tt = t * (1.0 - 3.5 / float(n + 1));
        i = p + float2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
        c += 1.0 / length(float2(p.x / (sin(i.x + tt) / strength), p.y / (cos(i.y + tt) / strength)));
    }
    c /= 5.0;
    c = 1.17 - pow(c, 1.4);
    return pow(abs(c), 7.0);
}

fragment float4 oceanCausticsFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 p = (uv - 0.5) * float2(a, 1.0);
    float2 m = (u.pointer - 0.5) * float2(a, 1.0);
    float2 dm = p - m;
    float rm = length(dm);
    // A fingertip in the water: rings travel out from the pointer and bend the light under them.
    float ring = sin(rm * 46.0 - u.time * 3.2) * exp(-rm * 6.0) * u.presence;
    float t = u.time * 0.32 + u.seed;
    float2 swell = float2(noise(p * 1.4 + float2(t * 0.05, 0.0)), noise(p * 1.4 + float2(4.0, -t * 0.05))) - 0.5;
    float2 w = p * 6.0 + swell * 0.9 + dm / (rm + 0.001) * ring * 0.10 - 250.0;

    // Three wavelengths focus at slightly different depths: a thin spectral rim on every line.
    float cr = caustic(w, t);
    float cg = caustic(w + float2(0.020, 0.012), t);
    float cb = caustic(w + float2(0.040, 0.024), t);
    float3 light = float3(cr, cg, cb);

    // Sand ripples and depth: deeper water in the upper left, a sandbar lower right.
    float depth = saturate(0.55 + 0.55 * (fbm(p * 0.9 + 3.0 + u.seed, 3) - 0.5) - (uv.y - 0.5) * 0.35 + (0.5 - uv.x) * 0.2);
    float sandRipple = 0.5 + 0.5 * sin(dot(p, float2(18.0, 31.0)) + 2.5 * noise(p * 6.0));
    float gold = saturate(u.golden);
    float3 sandDay = float3(0.92, 0.85, 0.68) * (0.92 + 0.08 * sandRipple);
    float3 sandNight = float3(0.16, 0.22, 0.34) * (0.92 + 0.08 * sandRipple);
    float3 sand = mix(sandNight, sandDay, u.daylight);
    sand = mix(sand, float3(0.95, 0.70, 0.55), gold * 0.45);
    // Water absorbs red first, then green: depth turns sand into turquoise, then into blue.
    float3 absorb = mix(float3(2.6, 0.95, 0.55), float3(2.2, 1.1, 0.9), gold * 0.5);
    float3 color = sand * exp(-absorb * (0.35 + depth * 1.25));
    float3 sun = mix(float3(0.55, 0.70, 1.00), float3(1.00, 0.98, 0.92), u.daylight);
    sun = mix(sun, float3(1.00, 0.72, 0.48), gold * 0.8);
    float reach = exp(-depth * 1.1) * mix(0.35, 1.0, u.daylight);
    color += light * sun * reach * 0.75 * (0.85 + 0.6 * smoothstep(0.0, 0.4, abs(ring)));
    color += float3(0.0, 0.04, 0.06) * (1.0 - u.daylight) * (1.0 - depth);
    return finish(shoulder(color * 1.15), in, u);
}

// MARK: Northern Lights

/// The curtain's footprint on the sky, seen from below: a wandering line across the sky,
/// with fine vertical rays along it. `h` runs 0 at the curtain's foot to 1 at its top.
static inline float auroraSheet(float2 xz, float h, float t) {
    float wander = 0.55 * sin(xz.x * 0.35 + t * 0.6) + 0.35 * sin(xz.x * 0.81 - t * 0.4 + 1.3)
        + 0.9 * (noise(float2(xz.x * 0.45 + t * 0.2, 3.7)) - 0.5);
    float line = xz.y - 4.0 - wander;
    float fold = exp(-line * line * 1.7);
    float far = saturate(xz.y * 0.08);
    float rays = noise(float2(xz.x * 6.0 + wander * 3.0, t * 0.9));
    rays = mix(0.25 + 0.95 * rays * rays, 0.6, far);
    float profile = smoothstep(0.0, 0.10, h) * exp(-h * 2.2);
    return fold * rays * profile;
}

static inline float3 auroraSky(float3 rd, float t, float daylight, float gold, float seed, float jitter) {
    float3 color = float3(0.0);
    if (rd.y <= 0.002) return color;
    const int slices = 10;
    for (int i = 0; i < slices; i++) {
        float h = (float(i) + jitter) / float(slices);
        float altitude = 0.6 + h * 1.6;
        float2 xz = rd.xz / rd.y * altitude;
        xz.x += seed;
        float d = auroraSheet(xz, h, t);
        float3 tone = mix(float3(0.10, 1.00, 0.55), float3(0.35, 0.55, 1.00), smoothstep(0.25, 0.65, h));
        tone = mix(tone, float3(0.95, 0.25, 0.80), smoothstep(0.55, 1.0, h));
        tone = mix(tone, float3(1.0, 0.45, 0.45), gold * 0.35);
        color += tone * d;
    }
    color *= 4.2 / float(slices);
    return color * (1.0 - daylight * 0.6) * smoothstep(0.0, 0.08, rd.y);
}

/// The far shore: a soft range with one or two peaks.
static inline float northRidge(float x, float seed) {
    float peaks = 1.0 - abs(2.0 * noise(float2(x * 1.3 + seed + 3.0, 1.7)) - 1.0);
    return 0.025 + 0.10 * peaks * peaks + 0.035 * fbm(float2(x * 4.0 + seed, 5.1), 3);
}

fragment float4 northernLightsFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 lean = (u.pointer - 0.5) * u.presence;
    float horizon = 0.70;
    float2 s = float2((uv.x - 0.5) * a + lean.x * 0.12, horizon - uv.y);
    float t = u.time * 0.06;
    float gold = saturate(u.golden);

    float3 zenith = mix(float3(0.004, 0.008, 0.022), float3(0.12, 0.24, 0.42), u.daylight);
    float3 low = mix(float3(0.012, 0.035, 0.060), float3(0.40, 0.52, 0.62), u.daylight);
    low = mix(low, float3(0.55, 0.26, 0.30), gold * 0.6);

    float jitter = hash21(in.position.xy + fract(u.time) * 61.0);
    float3 color;
    if (s.y > 0.0) {
        float3 rd = normalize(float3(s.x, s.y + 0.04 + lean.y * 0.04, 1.0));
        color = mix(low, zenith, pow(saturate(s.y / horizon), 0.6));
        color += starField(float2(s.x, s.y) * 1.2, 70.0, u.time, u.seed) * (1.0 - u.daylight) * 0.8;
        color += auroraSky(rd, t, u.daylight, gold, u.seed, jitter);
        // Mountains between sky and lake.
        float ridge = northRidge(s.x, u.seed);
        float m = smoothstep(ridge + 0.002, ridge, s.y);
        color = mix(color, low * 0.06 + float3(0.002, 0.004, 0.008), m);
    } else {
        // The lake: the sky again, mirrored, darker, shivering with small waves.
        float depthDown = -s.y;
        float shiver = (noise(float2(s.x * 40.0, depthDown * 300.0 / (depthDown + 0.05) + u.time * 0.8)) - 0.5) * 0.02 * depthDown;
        float3 rd = normalize(float3(s.x + shiver, depthDown + 0.04, 1.0));
        float3 sky = mix(low, zenith, pow(saturate(depthDown / horizon), 0.6));
        float3 mirrored = sky + auroraSky(rd, t, u.daylight, gold, u.seed, jitter);
        float fres = 0.35 + 0.45 * exp(-depthDown * 6.0);
        color = mirrored * fres + float3(0.001, 0.002, 0.004);
        float ridge = northRidge(s.x, u.seed);
        color = mix(color, low * 0.03, smoothstep(ridge * 0.6 + 0.002, ridge * 0.6, depthDown) * 0.85);
    }
    return finish(shoulder(color), in, u);
}

// MARK: Lava Lamp

fragment float4 lavaLampFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 p = float2((uv.x - 0.5) * a, uv.y);
    float2 m = float2((u.pointer.x - 0.5) * a, u.pointer.y);
    float t = u.time * 0.11;

    float f = 0.0;
    float2 g = float2(0.0);
    for (int i = 0; i < 9; i++) {
        float k = float(i);
        float2 c = float2(sin(t * (0.37 + k * 0.071) + k * 2.17 + u.seed) * a * 0.42,
                          0.5 + 0.58 * sin(t * (0.23 + k * 0.053) + k * 1.31));
        float r = 0.075 + 0.05 * fract(k * 0.618 + 0.2);
        float2 d = p - c;
        float d2 = dot(d, d) + 0.0004;
        float w = r * r / d2;
        f += w;
        g += -2.0 * w / d2 * d;
    }
    // Warmth under the pointer pulls a bubble of wax toward it.
    float2 dp = p - m;
    float dp2 = dot(dp, dp) + 0.0004;
    float wp = 0.09 * 0.09 / dp2 * u.presence;
    f += wp;
    g += -2.0 * wp / dp2 * dp;

    float edge = smoothstep(0.92, 1.08, f);
    float3 n = normalize(float3(-g * 0.012, 1.0));
    float gold = saturate(u.golden);
    float3 bg = mix(mix(float3(0.035, 0.012, 0.050), float3(0.10, 0.26, 0.32), u.daylight), float3(0.18, 0.05, 0.06), gold * 0.5);
    float3 waxLow = mix(mix(float3(0.95, 0.18, 0.42), float3(1.00, 0.42, 0.30), u.daylight), float3(1.00, 0.36, 0.14), gold);
    float3 waxHigh = mix(mix(float3(1.00, 0.55, 0.30), float3(1.00, 0.80, 0.45), u.daylight), float3(1.00, 0.78, 0.30), gold);
    float3 wax = mix(waxHigh, waxLow, uv.y);
    // The lamp glows from below, through the wax.
    float3 color = bg * (0.6 + 0.9 * smoothstep(0.2, 1.0, uv.y)) + wax * saturate(f * 0.5) * 0.10;
    float thick = smoothstep(1.0, 3.5, f);
    float3 body = wax * (0.55 + 0.45 * thick) * (0.75 + 0.35 * n.z);
    float rim = pow(1.0 - n.z, 2.0);
    body += waxHigh * rim * 0.5;
    float spec = pow(saturate(dot(n, normalize(float3(-0.4, -0.6, 1.0)))), 60.0);
    body += spec * 0.55;
    color = mix(color, body, edge);
    // The glass: a soft highlight down the left side.
    color += float3(1.0, 0.9, 0.95) * exp(-pow((uv.x - 0.12) * 9.0, 2.0)) * 0.035;
    return finish(shoulder(color * 1.05), in, u);
}

// MARK: Ink in Water

fragment float4 inkInWaterFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 p = (uv - 0.5) * float2(a, 1.0) * 1.35 + u.seed;
    float2 m = (u.pointer - 0.5) * float2(a, 1.0) * 1.35 + u.seed;
    float2 dm = p - m;
    float near = exp(-dot(dm, dm) * 3.0) * u.presence;
    p += dm * near * 0.45;   // the water parts around a fingertip
    float t = u.time * 0.018;
    float2 q = float2(fbm(p + float2(0.0, t), 4), fbm(p + float2(5.2, 1.3) - t, 4));
    float2 r = float2(fbm(p + 3.4 * q + float2(1.7, 9.2) + 0.6 * t, 4), fbm(p + 3.4 * q + float2(8.3, 2.8) - 0.5 * t, 4));
    float f = fbm(p + 3.0 * r, 4);
    float plume = smoothstep(0.40, 0.92, f);
    float wisp = pow(1.0 - abs(2.0 * f - 1.0), 6.0);
    float gold = saturate(u.golden);

    // By day: ink falling through clear water over white. By night: inks that glow.
    float3 paper = mix(float3(0.92, 0.92, 0.94), float3(0.98, 0.93, 0.86), gold * 0.6);
    float3 inkA = float3(0.06, 0.10, 0.36), inkB = float3(0.62, 0.08, 0.18);
    float3 dayInk = mix(inkA, inkB, smoothstep(0.35, 0.75, r.x));
    float3 day = mix(paper, dayInk, plume * 0.92);
    day = mix(day, dayInk * 0.6 + paper * 0.4, wisp * 0.25);

    float3 glowA = float3(0.04, 0.52, 0.62), glowB = float3(0.52, 0.16, 0.66);
    float3 nightInk = mix(glowA, glowB, smoothstep(0.35, 0.75, r.x));
    nightInk = mix(nightInk, float3(1.0, 0.45, 0.30), gold * 0.5);
    float3 night = float3(0.006, 0.010, 0.026) + nightInk * (plume * plume * 0.8 + wisp * 0.2);

    float3 color = mix(night, day, u.daylight);
    color += near * mix(nightInk, -dayInk * 0.2, u.daylight) * 0.06;
    return finish(color, in, u);
}

// MARK: Fireflies

/// One cell's light. `z` is nearness: near lights are larger and softer, like out-of-focus bokeh.
static inline float fireflyAt(float2 f, float2 cell, float2 offset, float cells, float z, float t, float seed) {
    float2 r = hash22(cell + seed);
    if (hash21(cell + seed + 9.1) < 0.5) return 0.0;
    float2 wander = float2(sin(t * (0.5 + r.x * 0.7) + r.y * 30.0), cos(t * (0.4 + r.y * 0.6) + r.x * 20.0)) * 0.3;
    float2 c = offset + 0.5 + (r - 0.5) * 0.35 + wander;
    float d = length(f - c) / cells;
    float size = mix(0.0022, 0.0105, z) * (0.7 + 0.6 * r.y);
    float x = d / size;
    float core = smoothstep(1.25, 0.65, x);      // a flat bokeh disc with a soft rim
    float halo = exp(-x * x * 0.12) * 0.16;
    float s = 0.5 + 0.5 * sin(t * (1.1 + r.x * 1.2) + r.y * 40.0);
    return (core + halo) * s * s;
}

fragment float4 firefliesFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 p = float2((uv.x - 0.5) * a, uv.y);
    float2 m = float2((u.pointer.x - 0.5) * a, u.pointer.y);
    float gold = saturate(u.golden);
    float night = 1.0 - u.daylight;
    float t = u.time * 0.5;

    // Evening sky: a last band of light low down, deep blue above.
    float3 top = mix(float3(0.008, 0.016, 0.040), float3(0.36, 0.55, 0.72), u.daylight);
    float3 low = mix(float3(0.050, 0.090, 0.120), float3(0.92, 0.88, 0.66), u.daylight);
    top = mix(top, float3(0.14, 0.10, 0.26), gold * 0.7);
    low = mix(low, float3(1.00, 0.55, 0.32), gold * 0.85);
    float3 color = mix(top, low, smoothstep(0.05, 0.80, uv.y));
    color += starField(p * 1.1, 60.0, u.time, u.seed) * night * 0.55 * smoothstep(0.7, 0.1, uv.y);

    // Three ridges of meadow, each nearer and darker; the grass sways.
    for (int i = 0; i < 3; i++) {
        float k = float(i);
        float base = 0.74 + k * 0.075;
        float bx = p.x * (90.0 + k * 60.0) + 2.0 * noise(float2(p.x * 9.0, k)) + 0.35 * sin(u.time * 0.6 + p.x * 3.0 + k);
        float blade = pow(saturate(1.0 - abs(fract(bx) - 0.5) * 2.0), 5.0);
        float blades = blade * (0.012 + 0.03 * hash21(float2(floor(bx), k + 1.0))) * (1.0 + k * 0.8);
        float edge = base - 0.05 * fbm(float2(p.x * (1.6 + k) + u.seed + k * 5.0, k), 3) - blades;
        float3 tone = mix(low * 0.30, top * 0.45, 0.4) * (1.0 - k * 0.3) * (1.0 - night * 0.55);
        color = mix(color, tone, smoothstep(edge, edge + 0.0025, uv.y));
    }

    float3 fly = mix(float3(1.00, 0.96, 0.80), float3(0.78, 1.00, 0.32), night);
    fly = mix(fly, float3(1.0, 0.76, 0.42), gold * 0.5);
    float lights = 0.0;
    for (int i = 0; i < 3; i++) {
        float z = float(i) / 2.0;
        float cells = mix(10.0, 3.2, z);
        float2 toward = (m - p) * 0.14 * u.presence * exp(-dot(m - p, m - p) * 3.5) * (0.5 + z);
        float2 q = (p + toward + float2(t * 0.004 * (1.0 + z), -t * 0.008 * (1.0 + z))) * cells;
        float2 id = floor(q), f = fract(q);
        float seed = u.seed + float(i) * 7.0;
        float layer = fireflyAt(f, id, float2(0.0), cells, z, t, seed);
        // Near lights are big enough to reach into the next cell: look at the nearest neighbours too.
        if (i == 2) {
            float2 side = float2(f.x < 0.5 ? -1.0 : 1.0, f.y < 0.5 ? -1.0 : 1.0);
            layer += fireflyAt(f, id + float2(side.x, 0.0), float2(side.x, 0.0), cells, z, t, seed);
            layer += fireflyAt(f, id + float2(0.0, side.y), float2(0.0, side.y), cells, z, t, seed);
            layer += fireflyAt(f, id + side, side, cells, z, t, seed);
        }
        lights += layer * mix(0.55, 0.9, z);
    }
    color += lights * fly * mix(0.6, 1.25, night) * smoothstep(0.0, 0.45, uv.y + 0.15);
    return finish(shoulder(color), in, u);
}

// MARK: Liquid Chrome

static inline float chromeHeight(float2 p, float t, float2 m, float presence) {
    float2 w = p + 0.45 * float2(sin(p.y * 0.9 + t), cos(p.x * 0.8 - t * 0.8));
    float h = 0.55 * sin(w.x * 1.2 + t) * cos(w.y * 1.4 - t * 0.7)
            + 0.22 * sin((w.x + w.y) * 2.1 + t * 1.3)
            + 0.07 * sin(w.x * 3.7 - w.y * 2.9 - t * 1.7);
    float2 d = p - m;
    float r2 = dot(d, d);
    // A drop presses into the mercury, and rings run out from it.
    h -= presence * (0.45 * exp(-r2 * 5.0) - 0.06 * sin(sqrt(r2 + 0.004) * 13.0 - t * 9.0) * exp(-r2 * 1.5));
    return h;
}

/// A photographer's studio, seen in the metal: a graded backdrop, a horizon strip, two softboxes.
static inline float3 studio(float3 r, float day, float gold) {
    float3 high = mix(float3(0.22, 0.26, 0.52), float3(0.92, 0.94, 0.98), day);
    float3 mid = mix(float3(0.30, 0.18, 0.46), float3(0.62, 0.66, 0.72), day);
    float3 deep = mix(float3(0.030, 0.034, 0.080), float3(0.10, 0.11, 0.13), day);
    float3 stripA = mix(float3(0.30, 0.85, 1.00), float3(1.0, 1.0, 1.0), day);
    float3 stripB = mix(float3(1.00, 0.35, 0.75), float3(1.0, 0.97, 0.92), day);
    high = mix(high, float3(1.00, 0.78, 0.62), gold * 0.6);
    mid = mix(mid, float3(0.80, 0.40, 0.30), gold * 0.6);
    stripB = mix(stripB, float3(1.0, 0.62, 0.35), gold * 0.7);
    float y = r.y;
    float3 c = mix(deep, mid, smoothstep(-0.6, 0.0, y));
    c = mix(c, high, smoothstep(0.0, 0.8, y));
    c += stripB * exp(-pow((y + 0.02) * 6.0, 2.0)) * 0.55;
    c += stripA * smoothstep(0.25, 0.6, r.x) * smoothstep(-0.1, 0.5, y) * 0.35;
    c += stripB * smoothstep(0.30, 0.7, -r.x) * smoothstep(0.2, 0.8, y) * 0.25;
    return c;
}

fragment float4 liquidChromeFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 p = (uv - 0.5) * float2(a, 1.0) * 1.6 + u.seed;
    float2 m = (u.pointer - 0.5) * float2(a, 1.0) * 1.6 + u.seed;
    float t = u.time * 0.12;
    const float e = 0.01;
    float h = chromeHeight(p, t, m, u.presence);
    float hx = chromeHeight(p + float2(e, 0.0), t, m, u.presence);
    float hy = chromeHeight(p + float2(0.0, e), t, m, u.presence);
    float3 n = normalize(float3(-(hx - h) / e * 0.55, (hy - h) / e * 0.55, 1.0));
    float3 r = reflect(float3(0.0, 0.0, -1.0), n);
    float gold = saturate(u.golden);
    float3 env = studio(r, u.daylight, gold);
    float fres = 0.75 + 0.25 * pow(1.0 - n.z, 5.0);
    float3 metal = mix(float3(0.93, 0.94, 0.97), float3(1.00, 0.86, 0.74), gold * 0.6);
    float3 color = env * metal * fres;
    // A faint oil-film colour in the troughs.
    float3 film = 0.5 + 0.5 * cos(6.2832 * (h * 0.7 + float3(0.0, 0.33, 0.67)));
    color = mix(color, color * film * 1.5, 0.10 * smoothstep(0.2, -0.6, h));
    return finish(shoulder(color * 1.1), in, u);
}

// MARK: - Wallpapers made from the owner's own picture

constexpr sampler wallSampler(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);

/// The texture coordinate that shows the picture the way the desktop does: filling the screen, centred.
static inline float2 coverUV(float2 uv, texture2d<float> tex, float a) {
    float ta = float(tex.get_width()) / float(max(tex.get_height(), 1u));
    float2 fit = ta > a ? float2(a / ta, 1.0) : float2(1.0, ta / a);
    return 0.5 + (uv - 0.5) * fit;
}

/// A soft blur from the mip chain. Four rotated taps hide the box shape of a single mip.
static inline float3 frosted(texture2d<float> tex, float2 tuv, float lod) {
    float2 texel = exp2(lod) / float2(tex.get_width(), tex.get_height());
    float3 sum = tex.sample(wallSampler, tuv + texel * float2(0.5, 0.2), level(lod)).rgb;
    sum += tex.sample(wallSampler, tuv + texel * float2(-0.2, 0.5), level(lod)).rgb;
    sum += tex.sample(wallSampler, tuv + texel * float2(-0.5, -0.2), level(lod)).rgb;
    sum += tex.sample(wallSampler, tuv + texel * float2(0.2, -0.5), level(lod)).rgb;
    return sum * 0.25;
}

/// The wallpaper's own finish: no vignette and no palette, so with nothing moving it is the
/// picture exactly. Dim and dither still apply.
static inline float4 finishPicture(float3 color, Varying in, constant Uniforms &u) {
    if (abs(u.contrast - 0.5) > 0.001) color = grade(color, u, false);
    else color *= 1.0 - u.dim * 0.85;
    color += tpdf(in.position.xy, u.time);
    if (u.grain > 0.001) color += (hash21(in.position.xy + fract(u.time * 7.13) * 431.0) - 0.5) * u.grain * 0.05;
    color = saturate(color);
    return float4(color * u.opacity, u.opacity);
}

// MARK: Rain on Your Wallpaper

fragment float4 wallpaperRainFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                      texture2d<float> wall [[texture(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 q = uv * float2(a, 1.0);
    float2 d = q - u.pointer * float2(a, 1.0);
    float clear = exp(-dot(d, d) * 12.0) * u.presence;

    DropSheet large = runningDrops(q, u.time, 1.0, 1.0 + u.seed);
    DropSheet small = runningDrops(q + 3.1, u.time * 1.2, 0.62, 5.0 + u.seed);
    DropSheet fine = mist(q, u.time, 46.0);
    DropSheet finer = mist(q + 0.37, u.time * 0.8, 92.0);
    float2 normal = large.normal + small.normal * (1.0 - large.lens);
    float lens = max(large.lens, small.lens);
    float keep = 1.0 - clear;
    float mistLens = max(fine.lens, finer.lens) * (1.0 - lens) * saturate(1.0 - large.wet - small.wet) * keep;
    normal += (fine.normal + finer.normal) * mistLens;
    lens = max(lens, mistLens);

    float2 base = coverUV(uv, wall, a);
    float wet = saturate(max(large.wet, small.wet) + clear * 1.2);
    // Fogged glass is a heavy blur; a wet trail or a wiped patch is nearly clear.
    float lod = mix(5.2, 0.8, wet);
    float3 color = frosted(wall, base, lod);
    float3 veil = mix(float3(0.80, 0.84, 0.90), float3(1.0, 0.86, 0.74), saturate(u.golden));
    color = mix(color, color * 0.82 + veil * 0.12, 0.55 * (1.0 - wet));

    if (lens > 0.001) {
        // A drop is a small lens: it shows a sharp, shrunken, upside-down piece of the scene behind it.
        float2 look = base - normal * float2(0.045 / a, 0.045) - (normal * 0.5) * 0.02;
        float3 inside = wall.sample(wallSampler, clamp(look, 0.0, 1.0), level(0.6)).rgb;
        float3 n = normalize(float3(normal, 0.75));
        float glint = pow(max(dot(n, normalize(float3(-0.35, -0.68, 0.62))), 0.0), 34.0);
        float rim = smoothstep(0.55, 1.0, length(normal));
        inside = inside * (1.0 - rim * 0.45) + glint * 0.55;
        color = mix(color, inside, lens);
    }
    return finishPicture(color, in, u);
}

// MARK: Ripples on Your Wallpaper

fragment float4 wallpaperRippleFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                        texture2d<float> wall [[texture(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    float2 q = uv * float2(a, 1.0);
    float2 slope = float2(0.0);
    // Now and then a drop lands somewhere on the pond.
    for (int i = 0; i < 4; i++) {
        float k = float(i);
        float period = 4.0 + k * 1.3;
        float tt = u.time / period + hash21(float2(k, u.seed));
        float age = fract(tt) * period;
        float2 c = hash22(float2(floor(tt) + k * 17.0, k + u.seed)) * float2(a, 1.0);
        float2 dv = q - c;
        float r = length(dv);
        float x = r - age * 0.11;
        if (abs(x) > 0.06) continue;   // far from this ring: nothing to add
        float wave = cos(x * 140.0) * exp(-x * x * 2600.0) * exp(-age * 0.75);
        slope += dv / (r + 0.0001) * wave * smoothstep(0.0, 0.01, r) * 1.4;
    }
    // Under the pointer the water answers with a steady ring of ripples.
    float2 dp = q - u.pointer * float2(a, 1.0);
    float rp = length(dp);
    float pw = cos(rp * 85.0 - u.time * 5.5) * exp(-rp * 9.0) * u.presence;
    slope += dp / (rp + 0.0001) * pw * smoothstep(0.0, 0.02, rp) * 0.7;

    float2 base = coverUV(uv, wall, a);
    float3 color = wall.sample(wallSampler, base - slope * 0.0045 * float2(1.0 / a, 1.0), level(0.0)).rgb;
    float light = dot(slope, normalize(float2(-0.6, -0.8)));
    color += max(light, 0.0) * 0.07 * float3(1.0, 0.98, 0.95) - max(-light, 0.0) * 0.035 * color;
    return finishPicture(color, in, u);
}

// MARK: Depth for Your Wallpaper

fragment float4 wallpaperDepthFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                       texture2d<float> wall [[texture(0)]]) {
    float a = aspect(u);
    float2 uv = field(in, u);
    // A slow breath of camera movement, and the pointer leaning the view.
    float t = u.time * 0.05;
    float2 drift = float2(sin(t * 0.83 + u.seed), sin(t * 0.61 + 1.7)) * 0.35;
    float2 lean = mix(drift, (u.pointer - 0.5) * 2.0, u.presence * 0.8);
    float zoom = 1.045;
    float2 base = 0.5 + (coverUV(uv, wall, a) - 0.5) / zoom;
    // Depth guessed from the picture: lower and brighter things read as nearer.
    float2 tuv = base;
    for (int i = 0; i < 2; i++) {
        float far = luma(wall.sample(wallSampler, tuv, level(5.5)).rgb);
        float depth = saturate(0.62 * tuv.y + 0.38 * far);
        tuv = base + lean * (depth - 0.45) * float2(0.016 / a * 1.6, 0.012);
    }
    float3 color = wall.sample(wallSampler, tuv, level(0.0)).rgb;
    // Dust in the light, nearer than anything in the picture.
    float2 p = float2(uv.x * a, uv.y) + lean * 0.03 + float2(0.0, -u.time * 0.004);
    float2 g = p * 18.0;
    float2 id = floor(g), f = fract(g) - 0.5;
    float2 r = hash22(id + u.seed);
    float on = step(0.86, hash21(id + 3.3));
    float2 c = (r - 0.5) * 0.6 + 0.12 * float2(sin(u.time * 0.3 + r.x * 20.0), cos(u.time * 0.25 + r.y * 20.0));
    float mote = exp(-dot(f - c, f - c) * 90.0) * on * (0.5 + 0.5 * sin(u.time * 0.8 + r.y * 30.0));
    color += mote * 0.06 * mix(float3(1.0, 0.95, 0.85), float3(0.8, 0.88, 1.0), 1.0 - u.daylight);
    return finishPicture(color, in, u);
}

// MARK: - Generated still wallpapers

static inline float3 toLinear(float3 c) { return pow(max(c, 0.0), 2.2); }
static inline float3 toDisplay(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }

static inline float3 oklab(float3 c) {
    float3 lms = float3(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b,
                        0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b,
                        0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b);
    lms = sign(lms) * pow(abs(lms), 1.0 / 3.0);
    return float3(0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
                  1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
                  0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z);
}

static inline float3 fromOklab(float3 l) {
    float3 lms = float3(l.x + 0.3963377774 * l.y + 0.2158037573 * l.z,
                        l.x - 0.1055613458 * l.y - 0.0638541728 * l.z,
                        l.x - 0.0894841775 * l.y - 1.2914855480 * l.z);
    lms = lms * lms * lms;
    return float3(4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                  -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                  -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z);
}

/// Five colours, packed: palette[0...3].rgb, and the fifth in palette[0...2].w.
static inline float3 meshColour(int i, constant Uniforms &u) {
    if (i < 4) return u.palette[i].rgb;
    return float3(u.palette[0].w, u.palette[1].w, u.palette[2].w);
}

/// A gradient mesh for a wallpaper image: soft fields of colour mixed in OKLab, so the seams
/// between two colours stay as bright and as saturated as the colours themselves.
/// `seed` places the fields, `daylight` and `golden` set the light of the hour.
fragment float4 meshWallpaperFragment(Varying in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float a = aspect(u);
    float2 p = (in.uv - 0.5) * float2(a, 1.0);
    float s = u.seed;
    // A slow, broad warp: fields fold into each other instead of meeting on straight lines.
    float2 w = float2(fbm(p * 0.8 + float2(s * 0.37, 1.3), 3), fbm(p * 0.8 + float2(4.1, s * 0.21), 3)) - 0.5;
    float2 q = p + w * 0.7;

    // Six fields with fixed roles: two of shadow, two of body, one of crest, one small highlight.
    // Weights are sharpened, so each colour owns a region and the seams between them are clean.
    const int roles[6] = { 1, 2, 1, 2, 3, 4 };
    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < 6; i++) {
        float k = float(i);
        float2 c = (hash22(float2(k * 3.7 + floor(s), 11.0 + fract(s) * 13.0)) - 0.5) * float2(a * 1.1, 1.1);
        float radius = (i == 5 ? 0.22 : 0.34) + 0.16 * hash21(float2(k, s + 2.0));
        // Each field is a long soft ellipse at its own angle: drapes of colour, not discs.
        float angle = hash21(float2(k + 5.0, s)) * 3.1416;
        float2 d = q - c;
        d = float2(dot(d, float2(cos(angle), sin(angle))), dot(d, float2(-sin(angle), cos(angle)))) * float2(0.62, 1.35);
        float weight = exp(-dot(d, d) / (radius * radius) * 1.6) + 0.00002;
        sum += oklab(toLinear(meshColour(roles[i], u))) * weight;
        total += weight;
    }
    // The deep colour fills wherever the fields thin out, mostly low on the screen.
    float ground = 0.04 + 0.10 * smoothstep(-0.1, 0.55, p.y);
    sum += oklab(toLinear(meshColour(0, u))) * ground;
    total += ground;
    float3 lab = sum / total;

    // A long fold of light across the screen, the drape of satin.
    float fold = sin(dot(q, float2(1.7, -2.3)) * 1.6 + fbm(q * 1.3 + s, 3) * 2.5);
    lab.x += fold * 0.035 * (0.5 + 0.5 * u.daylight);

    // The light of the hour: night lowers lightness and keeps colour; golden hour warms.
    float night = 1.0 - u.daylight;
    lab.x *= mix(1.0, 0.64, night);
    lab.yz *= mix(1.12, 1.18, night);
    lab.y += saturate(u.golden) * 0.012;
    lab.z += saturate(u.golden) * 0.022;
    // One broad sheen, the light on a real print.
    float sheen = smoothstep(0.9, 0.0, length((in.uv - float2(0.28, 0.22)) * float2(a * 0.7, 1.0)));
    lab.x += sheen * 0.045 * (0.4 + 0.6 * u.daylight);
    float3 color = toDisplay(max(fromOklab(lab), 0.0));
    float2 v = in.uv - 0.5;
    color *= 1.0 - dot(v, v) * 0.32;
    color += tpdf(in.position.xy, s);
    if (u.grain > 0.001) color += (hash21(in.position.xy * 1.13 + s) - 0.5) * u.grain * 0.04;
    return float4(saturate(color), 1.0);
}
