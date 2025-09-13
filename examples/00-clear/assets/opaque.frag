#version 440
/// Copyright 2023 Michael Pollind

layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 out_color;

void main(void)
{
    out_color = v_color;
}


