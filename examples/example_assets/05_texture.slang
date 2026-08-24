// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only
//
// One alpha-blended textured quad. The smallest shader that exercises the
// texture-upload, sampler and binding paths the web backends gained.

struct VSIn {
    float2 position : POSITION;
    float2 uv       : TEXCOORD0;
};

struct VSOut {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

[shader("vertex")]
VSOut vertexMain(VSIn input) {
    VSOut output;
    output.position = float4(input.position, 0.0, 1.0);
    output.uv = input.uv;
    return output;
}

// WebGPU reserves `@group(0)` for the uniform buffer that stands in for push
// constants, so textures move to group 1 there. `-DRHI_WGSL=1` selects it, the
// same switch the push-constant block uses in 02_mesh. GLSL ES ignores sets
// entirely -- SPIRV-Cross combines the pair into one `sampler2D` named after
// the texture.
#ifdef RHI_WGSL
[[vk::binding(0, 1)]] Texture2D<float4> tex;
[[vk::binding(1, 1)]] SamplerState smp;
#else
[[vk::binding(0, 0)]] Texture2D<float4> tex;
[[vk::binding(1, 0)]] SamplerState smp;
#endif

[shader("fragment")]
float4 fragmentMain(VSOut input) : SV_Target {
    return tex.Sample(smp, input.uv);
}
