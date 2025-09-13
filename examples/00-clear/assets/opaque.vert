#version 440
/// Copyright 2023 Michael Pollind

layout(location = 1) out vec4 v_color;

layout(location = 0) in vec3 a_position;
layout(location = 2) in vec4 a_color;

void main(void)
{
    v_color = a_color;
    gl_Position = vec4(a_position, 1.0)                                                                 ;
}

