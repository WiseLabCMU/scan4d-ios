#include <metal_stdlib>
using namespace metal;

// MARK: - Gaussian splats (SplatRenderer.swift, REQ-041)
//
// Each splat is one instanced quad, drawn back to front in the order the sort kernels below wrote,
// with premultiplied "over" blending. The projection follows the 3D Gaussian splatting paper:
// the 3D covariance is carried into screen space through the view rotation and the projection's
// Jacobian, and the quad covers the resulting 2D Gaussian out to about 2.8 sigma.
//
// Layouts must match the Swift structs of the same names in SplatRenderer.swift and SplatSOG.swift.

/// One splat, 40 bytes: its centre, the upper triangle of its 3D covariance, and its colour.
struct SplatGPU {
    packed_float3 position;
    packed_float3 covA;   // xx, xy, xz
    packed_float3 covB;   // yy, yz, zz
    uchar4 color;         // display sRGB, alpha = opacity
};

struct SplatUniforms {
    float4x4 modelView;
    float4x4 projection;
    float2 viewport;      // the render target, pixels
    float2 focal;         // focal length, pixels
    float2 tanHalfFov;
    uint linearOutput;    // 1 when the target stores linear colour (an _srgb or float format)
    float opacity;        // the whole splat's fade, 0...1
};

struct SplatVarying {
    float4 position [[position]];
    float2 local;         // the quad corner, in units where the Gaussian is exp(-dot(local, local))
    half4 color;
};

static float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

vertex SplatVarying splatVertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device SplatGPU *splats [[buffer(0)]],
                                const device uint *order [[buffer(1)]],
                                constant SplatUniforms &u [[buffer(2)]]) {
    SplatVarying out;
    // A culled splat: all four corners on one point outside the depth range, so nothing rasterizes.
    out.position = float4(0.0, 0.0, 2.0, 1.0);
    out.local = float2(0.0);
    out.color = half4(0.0);

    const SplatGPU s = splats[order[iid]];
    const float4 view = u.modelView * float4(float3(s.position), 1.0);
    const float depth = -view.z;
    if (depth < 0.01) { return out; }
    const float4 clip = u.projection * view;
    if (clip.w <= 0.0) { return out; }
    const float3 ndc = clip.xyz / clip.w;
    if (any(abs(ndc.xy) > 1.3)) { return out; }

    // The Jacobian of the perspective projection at this splat, with the offsets clamped as the
    // paper does so splats at the edge of the view don't blow up.
    const float2 limit = 1.3 * u.tanHalfFov;
    const float tx = clamp(view.x / depth, -limit.x, limit.x) * depth;
    const float ty = clamp(view.y / depth, -limit.y, limit.y) * depth;
    const float d2 = depth * depth;
    const float3x3 J = float3x3(float3(u.focal.x / depth, 0.0, 0.0),
                                float3(0.0, u.focal.y / depth, 0.0),
                                float3(u.focal.x * tx / d2, u.focal.y * ty / d2, 0.0));
    const float3x3 W = float3x3(u.modelView[0].xyz, u.modelView[1].xyz, u.modelView[2].xyz);
    const float3x3 V = float3x3(float3(s.covA[0], s.covA[1], s.covA[2]),
                                float3(s.covA[1], s.covB[0], s.covB[1]),
                                float3(s.covA[2], s.covB[1], s.covB[2]));
    const float3x3 T = J * W;
    const float3x3 cov = T * V * transpose(T);

    // Its 2D covariance, dilated by 0.3 px squared, and the axes of the ellipse it draws.
    const float a = cov[0][0] + 0.3;
    const float b = cov[0][1];
    const float c = cov[1][1] + 0.3;
    const float mid = 0.5 * (a + c);
    const float radius = length(float2(0.5 * (a - c), b));
    const float lambda1 = mid + radius;
    const float lambda2 = mid - radius;
    if (lambda2 <= 0.0) { return out; }
    const float2 major = abs(b) > 1e-9 ? normalize(float2(b, lambda1 - a))
                                       : (a >= c ? float2(1.0, 0.0) : float2(0.0, 1.0));
    const float2 axis1 = min(sqrt(2.0 * lambda1), 1024.0) * major;
    const float2 axis2 = min(sqrt(2.0 * lambda2), 1024.0) * float2(major.y, -major.x);

    const float2 corners[4] = { float2(-2.0, -2.0), float2(2.0, -2.0), float2(-2.0, 2.0), float2(2.0, 2.0) };
    const float2 corner = corners[vid & 3];
    const float2 offset = (corner.x * axis1 + corner.y * axis2) * 2.0 / u.viewport;

    float4 color = float4(s.color) / 255.0;
    if (u.linearOutput != 0) { color.rgb = srgbToLinear(color.rgb); }
    color.a *= u.opacity;

    out.position = float4(ndc.xy + offset, ndc.z, 1.0);
    out.local = corner;
    out.color = half4(color);
    return out;
}

fragment half4 splatFragment(SplatVarying in [[stage_in]]) {
    const half alpha = half(exp(-dot(in.local, in.local))) * in.color.a;
    if (alpha < half(1.0 / 255.0)) { discard_fragment(); }
    return half4(in.color.rgb * alpha, alpha);
}

// MARK: - Depth sort
//
// A counting sort on 16-bit depth keys, all on the GPU: keys and a histogram, then the histogram's
// exclusive prefix sum (the start of each key's run), then each splat scattered into its run.
// Ascending view-space z is far to near.

struct SplatSortParams {
    float4 axis;          // xyz: the view's z axis in the splat's own coordinates
    float zMin;
    float zScale;         // 65535 / (zMax - zMin)
    uint count;
    uint pad;
};

kernel void splatSortKeys(uint i [[thread_position_in_grid]],
                          const device SplatGPU *splats [[buffer(0)]],
                          device ushort *keys [[buffer(1)]],
                          device atomic_uint *histogram [[buffer(2)]],
                          constant SplatSortParams &p [[buffer(3)]]) {
    if (i >= p.count) { return; }
    const float z = dot(p.axis.xyz, float3(splats[i].position));
    const uint key = uint(clamp((z - p.zMin) * p.zScale, 0.0, 65535.0));
    keys[i] = ushort(key);
    atomic_fetch_add_explicit(&histogram[key], 1u, memory_order_relaxed);
}

/// One threadgroup of 256 threads, 256 keys each.
kernel void splatSortOffsets(device uint *histogram [[buffer(0)]],
                             uint t [[thread_position_in_threadgroup]]) {
    threadgroup uint partial[256];
    const uint base = t * 256;
    uint sum = 0;
    for (uint k = 0; k < 256; k++) { sum += histogram[base + k]; }
    partial[t] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (t == 0) {
        uint running = 0;
        for (uint k = 0; k < 256; k++) {
            const uint n = partial[k];
            partial[k] = running;
            running += n;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint running = partial[t];
    for (uint k = 0; k < 256; k++) {
        const uint n = histogram[base + k];
        histogram[base + k] = running;
        running += n;
    }
}

kernel void splatSortScatter(uint i [[thread_position_in_grid]],
                             const device ushort *keys [[buffer(0)]],
                             device atomic_uint *offsets [[buffer(1)]],
                             device uint *order [[buffer(2)]],
                             constant SplatSortParams &p [[buffer(3)]]) {
    if (i >= p.count) { return; }
    const uint slot = atomic_fetch_add_explicit(&offsets[keys[i]], 1u, memory_order_relaxed);
    order[slot] = i;
}
