// Rotating cube: vertex buffer (float3 position) + a `time` push constant.
// Compiled to SPIR-V (Vulkan) and MSL (Metal) by slangc (see build.zig).

struct VSInput {
    float3 position : POSITION;
};

struct VSOutput {
    float4 position : SV_Position;
    float3 color : COLOR0;
};

struct PushConsts {
    float time;
    float aspect;
    float y_sign; // +1 for Metal (NDC Y up), -1 for Vulkan (NDC Y down)
};

// WebGPU has no push constants, and slangc emits `[[vk::push_constant]]` as a
// WGSL `var<uniform>` with no `@group`/`@binding` attribute, which the browser
// rejects outright. Declaring the same block as an explicitly bound
// ConstantBuffer produces valid `@group(0) @binding(0) var<uniform>`; the
// WebGPU backend binds a uniform buffer there and `Cmd.set_push_constants`
// writes it. Selected by `-DRHI_WGSL=1` from examples/build.zig.
#ifdef RHI_WGSL
[[vk::binding(0, 0)]]
ConstantBuffer<PushConsts> pc;
#else
[[vk::push_constant]]
PushConsts pc;
#endif

float4x4 rotateY(float a) {
    float c = cos(a);
    float s = sin(a);
    return float4x4(
        c, 0, s, 0,
        0, 1, 0, 0,
        -s, 0, c, 0,
        0, 0, 0, 1);
}

float4x4 rotateX(float a) {
    float c = cos(a);
    float s = sin(a);
    return float4x4(
        1, 0, 0, 0,
        0, c, -s, 0,
        0, s, c, 0,
        0, 0, 0, 1);
}

float4x4 translate(float3 t) {
    return float4x4(
        1, 0, 0, t.x,
        0, 1, 0, t.y,
        0, 0, 1, t.z,
        0, 0, 0, 1);
}

// Right-handed perspective with depth in [0, 1] (Vulkan/Metal/D3D convention).
float4x4 perspective(float fovy, float aspect, float near, float far) {
    float f = 1.0 / tan(fovy * 0.5);
    return float4x4(
        f / aspect, 0, 0, 0,
        0, f, 0, 0,
        0, 0, far / (near - far), (near * far) / (near - far),
        0, 0, -1, 0);
}

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput o;
    o.color = input.position + float3(0.5, 0.5, 0.5);

    float4x4 model = mul(rotateY(pc.time), rotateX(pc.time * 0.7));
    float4x4 view = translate(float3(0.0, 0.0, -2.5));
    float4x4 proj = perspective(radians(60.0), pc.aspect, 0.1, 100.0);

    float4 clip = mul(proj, mul(view, mul(model, float4(input.position, 1.0))));
    clip.y *= pc.y_sign;
    o.position = clip;
    return o;
}

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return float4(input.color, 1.0);
}
