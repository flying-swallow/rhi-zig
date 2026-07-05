// Dear ImGui shader (see src/imgui.zig).
//
// Vertex stage: the ImDrawVert layout (float2 position, float2 uv, packed RGBA8
// color fed from a R8G8B8A8_UNORM attribute) transformed by a scale/translate
// push constant. Fragment stage: samples a SEPARATE texture + sampler (set 0,
// bindings 0 and 1) to match the RHI's descriptor model (rpi.Program uses
// separate sampled images and samplers, not combined).
//
// Compiled to SPIR-V by slangc via build.zig and embedded into the rhi module.
// slangc emits the entry points as "main" in SPIR-V.

struct VSInput {
    [[vk::location(0)]] float2 position : POSITION;
    [[vk::location(1)]] float2 uv : TEXCOORD0;
    [[vk::location(2)]] float4 color : COLOR0;
};

struct VSOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

struct PushConsts {
    float2 scale;
    float2 translate;
};
[[vk::push_constant]]
PushConsts pc;

[[vk::binding(0, 0)]] Texture2D uTexture;
[[vk::binding(1, 0)]] SamplerState uSampler;

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput o;
    o.uv = input.uv;
    o.color = input.color;
    // Vulkan NDC (Y down) matches ImGui's top-left origin directly.
    o.position = float4(input.position * pc.scale + pc.translate, 0.0, 1.0);
    return o;
}

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target {
    return input.color * uTexture.Sample(uSampler, input.uv);
}
