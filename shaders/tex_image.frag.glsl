#version 450

layout(location = 0) in vec3 in_color;
layout(location = 1) in vec2 in_uvs;

layout(location = 0) out vec4 out_frag_color;

layout(set = 0, binding = 0) uniform sampler2D image;

void main()
{
    out_frag_color = texture(image, in_uvs);
}

