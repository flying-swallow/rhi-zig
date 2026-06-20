#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 5 "/Users/michaelpollind/Documents/rhi-zig/example_assets/01_mandelbrot.slang"
struct pixelOutput_0
{
    float4 output_0 [[color(0)]];
};


#line 5
struct pixelInput_0
{
    float2 uv_0 [[user(TEXCOORD)]];
};


#line 21
[[fragment]] pixelOutput_0 fragmentMain(pixelInput_0 _S1 [[stage_in]], float4 position_0 [[position]])
{

    float2 _S2 = float2(_S1.uv_0.x * 3.0 - 2.09999990463256836, _S1.uv_0.y * 2.59999990463256836 - 1.29999995231628418);

#line 24
    float2 z_0 = float2(0.0, 0.0);

#line 24
    int i_0 = int(0);

#line 24
    pixelOutput_0 _S3 = { float4(0.0, 0.0, 0.0, 1.0) };

#line 42
    float3 _S4 = float3(0.0, 0.33000001311302185, 0.67000001668930054);

#line 28
    for(;;)
    {

#line 28
        if(i_0 < int(256))
        {
        }
        else
        {

#line 28
            break;
        }

#line 29
        float2 z_1 = float2(z_0.x * z_0.x - z_0.y * z_0.y, 2.0 * z_0.x * z_0.y) + _S2;
        if(dot(z_1, z_1) > 4.0)
        {

#line 31
            break;
        }

#line 28
        int _S5 = i_0 + int(1);

#line 28
        z_0 = z_1;

#line 28
        i_0 = _S5;

#line 28
    }

#line 35
    if(i_0 == int(256))
    {
        return _S3;
    }

#line 37
    pixelOutput_0 _S6 = { float4(0.5 + 0.5 * cos(6.28318023681640625 * (float(i_0) / 256.0 + _S4)), 1.0) };

#line 43
    return _S6;
}

