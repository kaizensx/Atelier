// Atelier app icon: the Facet mark in milled aluminium with a glacier-ice tip, rendered on the GPU.
// usage: swift icon.swift <size> <out.png> [samples] [--flat]
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let shader = #"""
#include <metal_stdlib>
using namespace metal;
struct P { uint size; uint samples; uint flat; uint pad; };

float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), f.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x), f.y);
}
// signed distance to a polygon (Inigo Quilez)
float sdPoly(float2 p, thread const float2 *v, int n) {
    float d = dot(p - v[0], p - v[0]); float s = 1.0;
    for (int i = 0, j = n - 1; i < n; j = i, i++) {
        float2 e = v[j] - v[i], w = p - v[i];
        float2 b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
        d = min(d, dot(b, b));
        bool3 c = bool3(p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x);
        if (all(c) || all(!c)) s *= -1.0;
    }
    return s * sqrt(d);
}
float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Mark geometry in mark space (x right, y UP, unit box).
constant float2 APEX = float2(0.5, 0.88), BL = float2(0.08, 0.10), BR = float2(0.92, 0.10);
constant float2 CA = float2(0.5, 0.52), CL = float2(0.34, 0.10), CR = float2(0.66, 0.10);
constant float CAPY = 0.715;

float3 shadeIcon(float2 uv, uint flatMode, thread float &alpha) {
    // icon space, y up, [-1,1]
    float2 p = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float px = 2.0 / 1024.0;
    float sq = sdRoundBox(p, float2(0.805), 0.37);
    alpha = clamp(0.5 - sq / px, 0.0, 1.0);

    // backdrop: deep ink-blue, lit from the top left, a cold floor light under the mark
    float3 a = float3(0.0075, 0.015, 0.038), b = float3(0.0009, 0.0014, 0.0035);
    float t = clamp(dot(p, normalize(float2(0.6, -0.8))) * 0.6 + 0.5, 0.0, 1.0);
    float3 col = mix(a, b, t);
    col += float3(0.03, 0.08, 0.18) * exp(-dot(p - float2(-0.55, 0.65), p - float2(-0.55, 0.65)) * 2.2) * 0.30;
    col += float3(0.10, 0.35, 0.55) * exp(-pow((p.y + 0.62) * 5.0, 2.0)) * exp(-p.x * p.x * 3.0) * 0.10;
    col += (hash(uv * 7919.0) - 0.5) * 0.004;

    // mark placement: centred, slightly high, 0.60 of the squircle
    float scale = 1.10;
    // ink box (y 0.10...0.88) centred, then lifted a touch: a triangle's weight sits low, so the
    // geometric centre looks low; 0.02 up puts its optical centre on the squircle's centre.
    float2 m = (p - float2(0.0, 0.011 + 0.020)) / scale + 0.5;
    float2 lit[4] = { APEX, BL, CL, CA };
    float2 shd[4] = { APEX, CA, CR, BR };
    float2 all6[6] = { APEX, BL, CL, CA, CR, BR };
    float dAll = sdPoly(m, all6, 6);
    float mpx = px / scale;

    // soft shadow of the mark on the backdrop
    float dS = sdPoly(m - float2(0.0, -0.045), all6, 6);
    col *= 1.0 - 0.85 * exp(-max(dS, 0.0) * 9.0) * smoothstep(-0.04, 0.02, dS);
    // the tip's light spills onto the backdrop
    float2 tipC = float2(0.5, 0.83);
    float tipD = length(m - tipC);
    col += float3(0.20, 0.65, 1.0) * exp(-tipD * tipD * 30.0) * 0.22 * (flatMode == 1 ? 0.0 : 1.0);

    float inside = clamp(0.5 - dAll / mpx, 0.0, 1.0);
    if (inside > 0.0) {
        bool onLit = sdPoly(m, lit, 4) <= sdPoly(m, shd, 4);
        bool cap = m.y > CAPY;
        float edge = -dAll;   // distance to the outline, inside
        float3 c;
        if (cap) {
            // glacier ice: luminous glass, brighter toward the summit, a cold core
            float h = clamp((m.y - CAPY) / (APEX.y - CAPY), 0.0, 1.0);
            float3 iceLo = float3(0.06, 0.45, 0.92), iceHi = float3(0.80, 0.98, 1.0);
            c = mix(iceLo, iceHi, pow(h, 0.8));
            if (!onLit) c *= float3(0.62, 0.78, 0.92);
            // inner refraction streaks
            c += 0.10 * vnoise(float2(m.x * 60.0, m.y * 18.0)) * float3(0.6, 0.9, 1.0);
            // the cut line where ice meets metal: a bright seam
            c += float3(0.6, 0.95, 1.0) * exp(-pow((m.y - CAPY) / 0.006, 2.0)) * 0.9;
            c *= 1.25;
        } else {
            // milled aluminium, brushed along each facet's own edge
            float2 dir = onLit ? normalize(APEX - BL) : normalize(APEX - BR);
            float2 nrm = float2(-dir.y, dir.x);
            float along = dot(m, dir), across = dot(m, nrm);
            float brush = vnoise(float2(along * 6.0, across * 900.0)) * 0.6 + vnoise(float2(along * 2.0, across * 300.0)) * 0.4;
            if (onLit) {
                float g = clamp(1.0 - (APEX.y - m.y) * 0.55 - (m.x - 0.2) * 0.25, 0.0, 1.0);
                c = mix(float3(0.50, 0.55, 0.62), float3(0.88, 0.91, 0.96), g);
                // a soft specular band sweeping across the face
                float band = exp(-pow((dot(m - float2(0.32, 0.55), float2(0.85, 0.53))) * 6.5, 2.0));
                c += band * 0.16;
            } else {
                float g = clamp((m.y - 0.10) / 0.78, 0.0, 1.0);
                c = mix(float3(0.055, 0.070, 0.100), float3(0.17, 0.20, 0.26), g);
                float band = exp(-pow((dot(m - float2(0.70, 0.40), float2(-0.85, 0.53))) * 7.0, 2.0));
                c += band * 0.06;
            }
            c *= 0.92 + 0.16 * brush;
            // a cold reflection of the backdrop at the foot of the mark
            c = mix(c, c * float3(0.75, 0.85, 1.05), smoothstep(0.35, 0.10, m.y) * 0.5);
        }
        // chamfer: a fine bright edge on the light side, darker on the far side
        float bevel = 0.012;
        float k = exp(-pow(edge / bevel, 2.0));
        float side = onLit ? 1.0 : 0.35;
        if (cap) side = 1.3;
        c += k * 0.35 * side;
        // the ridge between the facets: a crisp highlight line
        float ridge = abs(m.x - 0.5);
        if (m.y > CA.y) c += exp(-pow(ridge / 0.0035, 2.0)) * (cap ? 0.5 : 0.22);
        col = mix(col, c, inside);
    }
    // squircle finish: a hairline of light on the top edge, a shade at the bottom
    float e = exp(-pow(sq / 0.005, 2.0));
    col += e * (0.10 * clamp(p.y, 0.0, 1.0) + 0.012);
    col *= 1.0 - 0.12 * dot(p, p) * 0.5;
    return col;
}

kernel void render(texture2d<float, access::write> out [[texture(0)]], constant P &prm [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= prm.size || gid.y >= prm.size) return;
    float3 acc = 0; float aacc = 0; uint s = prm.samples;
    for (uint j = 0; j < s; j++) for (uint i = 0; i < s; i++) {
        float2 uv = (float2(gid) + (float2(i, j) + 0.5) / float(s)) / float(prm.size);
        float a; float3 c = shadeIcon(uv, prm.flat, a);
        acc += c * a; aacc += a;
    }
    float a = aacc / float(s * s);
    float3 c = aacc > 0 ? acc / aacc : float3(0);
    c = c / (1.0 + c * 0.12) * 1.06;
    out.write(float4(saturate(c), a), gid);
}
"""#

let args = CommandLine.arguments
let size = UInt32(args[1])!, outPath = args[2]
let samples = UInt32(args.count > 3 ? args[3] : "3")!
let flat: UInt32 = args.contains("--flat") ? 1 : 0
let device = MTLCreateSystemDefaultDevice()!
let lib = try! device.makeLibrary(source: shader, options: nil)
let pipe = try! device.makeComputePipelineState(function: lib.makeFunction(name: "render")!)
let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(size), height: Int(size), mipmapped: false)
desc.usage = [.shaderWrite]; desc.storageMode = .shared
let tex = device.makeTexture(descriptor: desc)!
var prm = (size, samples, flat, UInt32(0))
let q = device.makeCommandQueue()!
let cb = q.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(pipe); enc.setTexture(tex, index: 0)
enc.setBytes(&prm, length: MemoryLayout.size(ofValue: prm), index: 0)
enc.dispatchThreads(MTLSize(width: Int(size), height: Int(size), depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
if let e = cb.error { print("GPU error", e); exit(1) }
let w = Int(size)
var half = [UInt16](repeating: 0, count: w * w * 4)
tex.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, w), mipmapLevel: 0)
var px = [UInt16](repeating: 0, count: w * w * 4)
DispatchQueue.concurrentPerform(iterations: w) { y in
    for x in 0..<w {
        let i = y * w + x
        let a = Float(Float16(bitPattern: half[i * 4 + 3]))
        for ch in 0..<3 {
            var v = Float(Float16(bitPattern: half[i * 4 + ch]))
            v = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
            px[i * 4 + ch] = UInt16(max(0, min(1, v * a)) * 65535)
        }
        px[i * 4 + 3] = UInt16(max(0, min(1, a)) * 65535)
    }
}
let data = px.withUnsafeBytes { Data($0) }
let img = CGImage(width: w, height: w, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                  provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
print("wrote", outPath, w)
