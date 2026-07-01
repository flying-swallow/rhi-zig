#version 440
/// Copyright 2023 Michael Pollind

layout(location = 0) out vec2 v_uv;

void main(void)
{
    v_uv = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(v_uv * vec2(2, -2) + vec2(-1, 1), 0, 1.0);
}

