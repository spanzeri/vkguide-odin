#version 450

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uvs;
layout(location = 2) flat in uint in_flags;

layout(set = 0, binding = 0) uniform sampler2D font_atlas;

layout(location = 0) out vec4 out_frag_color;

const uint IS_TEXT = 1u << 0;

void main()
{
    if ((in_flags & IS_TEXT) != 0) {
        out_frag_color = texture(font_atlas, in_uvs) * in_color;
    } else {
        out_frag_color = in_color;
    }
}

