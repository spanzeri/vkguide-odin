#version 450
#extension GL_EXT_buffer_reference : require

struct UiVertex {
    vec2 position;
    vec2 uvs;
    vec3 color;
    uint flags;
};

layout(buffer_reference, std430) readonly buffer UiVertexBuffer {
    UiVertex vertices[];
};

layout(push_constant) uniform PushConstants {
    UiVertexBuffer vertex_buffer;
} push_constants;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uvs;
layout(location = 2) out uint out_flags;

void main()
{
    UiVertex v = push_constants.vertex_buffer.vertices[gl_VertexIndex];
    gl_Position = vec4(v.position, 1.0, 1.0);
    out_color = vec4(v.color, 1.0);
    out_uvs = v.uvs;
    out_flags = v.flags;
}

