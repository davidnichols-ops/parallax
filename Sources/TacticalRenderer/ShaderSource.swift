import Foundation

/// Metal shader source embedded as a Swift string. This avoids bundle-loading
/// issues in Swift Package Manager, where `.metal` files in library targets
/// don't generate `Bundle.module` unless resources are explicitly declared.
/// The source is compiled at renderer init via `device.makeLibrary(source:)`.
public enum ShaderSource {
    public static let msl: String = """
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct Uniforms {
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 viewProjection;
    float3   cameraPosition;
    float    time;
    float2   viewportSize;
    float    pixelDensity;
    float    _padding;
};

struct NodeInstance {
    float3   position;
    float    radius;
    float4   color;
    float    glowIntensity;
    float    selected;
    float    locked;
    float    _padding1;
    float    _padding2;
};

struct EdgeInstance {
    float3   start;
    float3   end;
    float    thickness;
    float4   color;
    float    flux;
    float    severed;
    float    sealed;
    float    conduit;
    float    phase;
};

struct FaceInstance {
    float3   v0;
    float3   v1;
    float3   v2;
    float4   color;
    float    alpha;
    float    _padding[3];
};

struct NodeVertexOut {
    float4 position [[position]];
    float3 normal;
    float3 worldPos;
    float  glow     [[flat]];
    float4 color    [[flat]];
    float  selected [[flat]];
    float  locked   [[flat]];
    float2 tokenCoord;
};

vertex NodeVertexOut node_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms& u [[buffer(0)]],
    constant NodeInstance* instances [[buffer(1)]],
    constant float3* verts [[buffer(2)]],
    constant float3* normals [[buffer(3)]]
) {
    NodeInstance inst = instances[iid];
    // Flatten the old icosahedron into an illuminated token-disc lying on the
    // tabletop layer. The remaining height keeps a faceted sci-fi silhouette.
    float3 local = verts[vid] * inst.radius;
    local.y *= 0.20;
    float3 world = local + inst.position;
    float4 clip = u.viewProjection * float4(world, 1.0);
    NodeVertexOut out;
    out.position = clip;
    out.normal = normals[vid];
    out.worldPos = world;
    out.glow = inst.glowIntensity;
    out.color = inst.color;
    out.selected = inst.selected;
    out.locked = inst.locked;
    out.tokenCoord = local.xz / max(inst.radius, 0.001);
    return out;
}

fragment float4 node_fragment(
    NodeVertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]]
) {
    float3 lightDir = normalize(float3(0.5, 0.8, 0.3));
    float diffuse = max(dot(normalize(in.normal), lightDir), 0.0);
    float ambient = 0.4;
    float3 viewDir = normalize(u.cameraPosition - in.worldPos);
    float rim = pow(1.0 - max(dot(normalize(in.normal), viewDir), 0.0), 2.0);
    float3 base = in.color.rgb * (ambient + diffuse * 0.6);
    base += in.color.rgb * rim * 0.3;
    base += in.color.rgb * in.glow * 0.5;
    if (in.selected > 0.5) {
        base += float3(1.0, 0.9, 0.5) * 0.4;
    }
    if (in.locked > 0.5) {
        base += in.color.rgb * 0.2;
    }
    // Compact internal circuitry marks give the red discs the distinct,
    // constantly-moving token language of a tactile holographic game.
    float2 p = in.tokenCoord;
    float diagonal = 1.0 - smoothstep(0.028, 0.075, abs(abs(p.x) - abs(p.y)));
    float inside = 1.0 - smoothstep(0.72, 0.88, length(p));
    float ring = smoothstep(0.58, 0.63, length(p)) - smoothstep(0.73, 0.79, length(p));
    float scan = 0.86 + 0.14 * sin(in.worldPos.z * 6.0 - u.time * 3.0);
    base *= scan;
    base += float3(1.0, 0.78, 0.26) * (diagonal * inside * 0.35 + ring * 0.22);
    return float4(base, in.color.a);
}

struct EdgeVertexOut {
    float4 position [[position]];
    float4 color    [[flat]];
    float  flux     [[flat]];
    float  severed  [[flat]];
    float  sealed   [[flat]];
    float  conduit  [[flat]];
    float  phase    [[flat]];
    float  along;
};

vertex EdgeVertexOut edge_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms& u [[buffer(0)]],
    constant EdgeInstance* instances [[buffer(1)]],
    constant float2* quadVerts [[buffer(2)]]
) {
    EdgeInstance inst = instances[iid];
    float3 dir = normalize(inst.end - inst.start);
    float3 toCam = normalize(u.cameraPosition - inst.start);
    float3 side = normalize(cross(dir, toCam));
    float2 qv = quadVerts[vid];
    float t = qv.x;
    float3 point = mix(inst.start, inst.end, t);
    point += side * qv.y * inst.thickness;
    float4 clip = u.viewProjection * float4(point, 1.0);
    EdgeVertexOut out;
    out.position = clip;
    out.color = inst.color;
    out.flux = inst.flux;
    out.severed = inst.severed;
    out.sealed = inst.sealed;
    out.conduit = inst.conduit;
    out.phase = inst.phase;
    out.along = t;
    return out;
}

fragment float4 edge_fragment(
    EdgeVertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]]
) {
    float3 base = in.color.rgb;
    float travellingPulse = 0.78 + 0.22 * sin((in.along - u.time * 0.72 + in.phase) * 22.0);
    base *= (0.3 + in.flux * 0.7) * travellingPulse;
    if (in.sealed > 0.5) {
        base += in.color.rgb * 0.3;
    }
    if (in.conduit > 0.5) {
        base += float3(0.1, 0.15, 0.3) * 0.3;
    }
    if (in.severed > 0.5) {
        base = float3(0.3, 0.05, 0.05);
    }
    return float4(base, in.color.a);
}

struct FaceVertexOut {
    float4 position [[position]];
    float4 color    [[flat]];
    float  alpha    [[flat]];
    float3 worldPos;
};

vertex FaceVertexOut face_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms& u [[buffer(0)]],
    constant FaceInstance* instances [[buffer(1)]]
) {
    FaceInstance inst = instances[iid];
    float3 pos;
    if (vid == 0) pos = inst.v0;
    else if (vid == 1) pos = inst.v1;
    else pos = inst.v2;
    float4 clip = u.viewProjection * float4(pos, 1.0);
    FaceVertexOut out;
    out.position = clip;
    out.color = inst.color;
    out.alpha = inst.alpha;
    out.worldPos = pos;
    return out;
}

fragment float4 face_fragment(
    FaceVertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]]
) {
    float scan = 0.80 + 0.20 * sin(in.worldPos.y * 4.0 - u.time * 2.2);
    return float4(in.color.rgb * scan, in.alpha);
}
"""
}
