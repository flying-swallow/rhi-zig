// Copyright 2023 Michael Pollind
// Fullscreen-triangle mandelbrot, authored in Slang. Compiled to SPIR-V for the
// Vulkan backend and to MSL for the Metal backend by slangc (see build.zig).

struct VSOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VSOutput vertexMain(uint vid : SV_VertexID) {
    VSOutput o;
    o.uv = float2(float((vid << 1) & 2), float(vid & 2));
    o.position = float4(o.uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

static const int RECURSION_LIMIT = 256;

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    // Map screen UV (0..1) to the complex plane, framing the whole set.
    float2 uv = input.uv;
    float2 c = float2(uv.x * 3.0 - 2.1, uv.y * 2.6 - 1.3);

    float2 z = float2(0.0, 0.0);
    int i = 0;
    for (; i < RECURSION_LIMIT; i++) {
        z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
        if (dot(z, z) > 4.0) {
            break;
        }
    }

    if (i == RECURSION_LIMIT) {
        // Inside the set.
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // Smooth iteration count -> cyclic palette.
    float t = float(i) / float(RECURSION_LIMIT);
    float3 col = 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
    return float4(col, 1.0);
}
