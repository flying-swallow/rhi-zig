// 04-svt — software virtual texturing, driven through the rhi `rpi` layer.
// This file holds the shared vertex stage + the final composite fragment stage.
// The feedback fragment stage lives in 04_svt_feedback.slang so neither program's
// SPIR-V carries a descriptor the other one owns.

// Composite program bindings (set 0). Distinct from the feedback program's b0.
[[vk::binding(1)]] Texture2D<float4> pageTable;   // "s_page_table"
[[vk::binding(2)]] Texture2D<float4> atlas;       // "s_atlas"
[[vk::binding(3)]] SamplerState pageSampler;      // "page_sampler"
[[vk::binding(4)]] SamplerState atlasSampler;     // "atlas_sampler"

struct PushConsts {
    float4x4 mvp;
    float pageTableSize;        // finest indirection grid (e.g. 64)
    float virtualTextureSize;   // logical texels per side (e.g. 8192)
    float mipCount;             // number of mip levels (e.g. 7)
    float mipBias;              // shifts requested detail coarser (+) / finer (-)
    float atlasCount;           // resident tiles per atlas side
    float borderScale;          // tileSize / pageSize
    float borderOffset;         // border / pageSize
    float _pad;
};
[[vk::push_constant]] PushConsts pc;

struct VSInput {
    float3 position : POSITION;
    float2 uv : TEXCOORD0;
};

struct VSOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VSOutput vertexMain(VSInput input) {
    VSOutput o;
    float4 clip = mul(pc.mvp, float4(input.position, 1.0));
    clip.y = -clip.y; // Vulkan NDC has Y pointing down.
    o.position = clip;
    o.uv = input.uv;
    return o;
}

// Screen-space mip selection (bgfx virtualtexture.sh MipLevel), identical to
// the feedback pass so the composite reads the same page the feedback requested.
float mipLevel(float2 uv, float texSize) {
    float2 dx = ddx(uv * texSize);
    float2 dy = ddy(uv * texSize);
    float d = max(dot(dx, dx), dot(dy, dy));
    return max(0.5 * log2(d), 0.0);
}

[shader("fragment")]
float4 compositeMain(VSOutput input) : SV_Target {
    float2 uv = frac(input.uv);

    // Pick the mip this pixel wants from screen-space derivatives, then read the
    // page table AT THAT LEVEL (the table is a full mip pyramid). Distant pixels
    // sample a coarse level → a coarse resident tile, so detail scales down with
    // distance instead of clinging to whatever fine tile is still resident.
    // The texel packs the atlas tile (r,g), the resident tile's mip (b) — which
    // may be coarser than `mipf` if the exact page isn't resident — and a
    // validity flag (a), each as a byte / 255.
    float mipf = clamp(floor(mipLevel(uv, pc.virtualTextureSize) - pc.mipBias), 0.0, pc.mipCount - 1.0);
    float4 entry = pageTable.SampleLevel(pageSampler, uv, mipf);
    if (entry.a < 0.5) {
        return float4(0.02, 0.02, 0.08, 1.0); // nothing resident yet
    }

    float ax = floor(entry.r * 255.0 + 0.5);
    float ay = floor(entry.g * 255.0 + 0.5);
    float mip = floor(entry.b * 255.0 + 0.5);

    // UV within the resident tile, then inset past the 1px border so linear
    // filtering never bleeds between unrelated tiles.
    float tilesAtMip = pc.pageTableSize / exp2(mip);
    float2 tileUv = frac(uv * tilesAtMip);
    float2 intra = tileUv * pc.borderScale + pc.borderOffset;
    float2 atlasUv = (float2(ax, ay) + intra) / pc.atlasCount;

    return atlas.SampleLevel(atlasSampler, atlasUv, 0.0);
}
