// 04-svt feedback fragment stage. Rendered at low resolution with no color
// target: each covered texel writes the id of the virtual page it wants into an
// SSBO (bound by name through the rhi `rpi` layer). The CPU reads it back a few
// frames later to decide which tiles to stream. Pairs with the shared vertexMain
// in 04_svt.slang.

[[vk::binding(0)]] RWStructuredBuffer<uint> feedback;   // "feedback_buffer"

struct PushConsts {
    float4x4 mvp;
    float pageTableSize;
    float virtualTextureSize;
    float mipCount;
    float mipBias;
    float atlasCount;
    float borderScale;
    float borderOffset;
    float _pad;
};
[[vk::push_constant]] PushConsts pc;

struct VSOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

// Base linear index of `mip` within the mip-pyramid page numbering:
// sum over coarser-than-mip levels of (pageTableSize >> i)^2.
uint pageOffset(uint mip, uint pts) {
    uint off = 0;
    for (uint i = 0; i < mip; i++) {
        uint s = pts >> i;
        off += s * s;
    }
    return off;
}

// Screen-space mip selection (bgfx virtualtexture.sh MipLevel).
float mipLevel(float2 uv, float texSize) {
    float2 dx = ddx(uv * texSize);
    float2 dy = ddy(uv * texSize);
    float d = max(dot(dx, dx), dot(dy, dy));
    return max(0.5 * log2(d), 0.0);
}

[shader("fragment")]
void feedbackMain(VSOutput input) {
    float2 uv = frac(input.uv);
    uint pts = (uint)pc.pageTableSize;

    float mipf = floor(mipLevel(uv, pc.virtualTextureSize) - pc.mipBias);
    mipf = clamp(mipf, 0.0, pc.mipCount - 1.0);
    uint mip = (uint)mipf;

    uint sizeAtMip = pts >> mip;
    uint x = min((uint)(uv.x * (float)sizeAtMip), sizeAtMip - 1);
    uint y = min((uint)(uv.y * (float)sizeAtMip), sizeAtMip - 1);

    uint idx = pageOffset(mip, pts) + y * sizeAtMip + x;
    feedback[idx] = 1u;
}
