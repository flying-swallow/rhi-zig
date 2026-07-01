#version 440

layout(location = 0) in vec3 a_pos;
layout(location = 0) out vec3 v_color;

layout(push_constant) uniform PushConsts {
    float time;
} pc;

mat4 rotateY(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat4(
        c, 0, s, 0,
        0, 1, 0, 0,
        -s, 0, c, 0,
        0, 0, 0, 1
    );
}

mat4 rotateX(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat4(
        1, 0, 0, 0,
        0, c, -s, 0,
        0, s, c, 0,
        0, 0, 0, 1
    );
}

void main() {
    v_color = a_pos + vec3(0.5);
    mat4 model = rotateY(pc.time) * rotateX(pc.time * 0.7);
    gl_Position = model * vec4(a_pos * 0.5, 1.0);
}
