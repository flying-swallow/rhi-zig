#include <metal_stdlib>
#include <metal_math>
#include <metal_texture>
using namespace metal;

#line 652 "core.meta.slang"
float float_getPi_0()
{

#line 652
    return 3.14159274101257324;
}


#line 21 "/Users/michaelpollind/Documents/rhi-zig/example_assets/02_mesh.slang"
matrix<float,int(4),int(4)>  rotateY_0(float a_0)
{

#line 22
    float c_0 = cos(a_0);
    float s_0 = sin(a_0);
    return matrix<float,int(4),int(4)> (c_0, 0.0, s_0, 0.0, 0.0, 1.0, 0.0, 0.0, - s_0, 0.0, c_0, 0.0, 0.0, 0.0, 0.0, 1.0);
}


#line 31
matrix<float,int(4),int(4)>  rotateX_0(float a_1)
{

#line 32
    float c_1 = cos(a_1);
    float s_1 = sin(a_1);
    return matrix<float,int(4),int(4)> (1.0, 0.0, 0.0, 0.0, 0.0, c_1, - s_1, 0.0, 0.0, s_1, c_1, 0.0, 0.0, 0.0, 0.0, 1.0);
}


#line 41
matrix<float,int(4),int(4)>  translate_0(float3 t_0)
{

#line 42
    return matrix<float,int(4),int(4)> (1.0, 0.0, 0.0, t_0.x, 0.0, 1.0, 0.0, t_0.y, 0.0, 0.0, 1.0, t_0.z, 0.0, 0.0, 0.0, 1.0);
}


#line 12338 "hlsl.meta.slang"
float radians_0(float x_0)
{

#line 12349
    return x_0 * (float_getPi_0() / 180.0);
}


#line 50 "/Users/michaelpollind/Documents/rhi-zig/example_assets/02_mesh.slang"
matrix<float,int(4),int(4)>  perspective_0(float fovy_0, float aspect_0, float near_0, float far_0)
{

#line 51
    float f_0 = 1.0 / tan(fovy_0 * 0.5);



    float _S1 = near_0 - far_0;

#line 52
    return matrix<float,int(4),int(4)> (f_0 / aspect_0, 0.0, 0.0, 0.0, 0.0, f_0, 0.0, 0.0, 0.0, 0.0, far_0 / _S1, near_0 * far_0 / _S1, 0.0, 0.0, -1.0, 0.0);
}


#line 8
struct VSOutput_0
{
    float4 position_0 [[position]];
    float3 color_0 [[user(COLOR)]];
};


#line 8
struct vertexInput_0
{
    float3 position_1 [[attribute(0)]];
};

struct PushConsts_0
{
    float time_0;
    float aspect_1;
    float y_sign_0;
};


#line 60
[[vertex]] VSOutput_0 vertexMain(vertexInput_0 _S2 [[stage_in]], PushConsts_0 constant* pc_0 [[buffer(0)]])
{

#line 61
    thread VSOutput_0 o_0;
    (&o_0)->color_0 = _S2.position_1 + float3(0.5, 0.5, 0.5);

#line 68
    thread float4 clip_0 = (((((((((float4(_S2.position_1, 1.0)) * ((((rotateX_0(pc_0->time_0 * 0.69999998807907104)) * (rotateY_0(pc_0->time_0)))))))) * (translate_0(float3(0.0, 0.0, -2.5)))))) * (perspective_0(radians_0(60.0), pc_0->aspect_1, 0.10000000149011612, 100.0))));
    clip_0.y = clip_0.y * pc_0->y_sign_0;
    (&o_0)->position_0 = clip_0;
    return o_0;
}
