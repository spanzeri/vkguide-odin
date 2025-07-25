#version 450
#extension GL_EXT_buffer_reference : require

layout(location = 0) out vec3 out_color;
layout(location = 1) out vec2 out_uv;

struct Vertex {
    vec3 position;
    float uv_x;
    vec3 normal;
    float uv_y;
    vec4 color;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
    Vertex vertices[];
};

layout(push_constant) uniform PushConstants {
    mat4 render_matrix;
    VertexBuffer vertex_buffer;
} push_constants;

void main()
{
    Vertex v = push_constants.vertex_buffer.vertices[gl_VertexIndex];
    gl_Position = push_constants.render_matrix * vec4(v.position, 1.0);
    out_color = v.color.rgb;
    out_uv = vec2(v.uv_x, v.uv_y);
}
