#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 8 "/Users/michaelpollind/Documents/rhi-zig/example_assets/02_mesh.slang"
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 8
struct pixelInput_0
{
    float3 color_0 [[user(COLOR)]];
};


#line 75
[[fragment]] pixelOutput_0 fragmentMain(pixelInput_0 _S1 [[stage_in]], float4 position_0 [[position]])
{

#line 75
    pixelOutput_0 _S2 = { float4(_S1.color_0, 1.0) };
    return _S2;
}

