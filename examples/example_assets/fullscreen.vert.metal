#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 5 "/Users/michaelpollind/Documents/rhi-zig/example_assets/01_mandelbrot.slang"
struct VSOutput_0
{
    float4 position_0 [[position]];
    float2 uv_0 [[user(TEXCOORD)]];
};

[[vertex]] VSOutput_0 vertexMain(uint vid_0 [[vertex_id]])
{

#line 12
    thread VSOutput_0 o_0;
    float2 _S1 = float2(float(vid_0 << int(1) & 2U), float(vid_0 & 2U));

#line 13
    (&o_0)->uv_0 = _S1;
    (&o_0)->position_0 = float4(_S1 * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o_0;
}

