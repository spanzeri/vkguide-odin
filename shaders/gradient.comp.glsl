#version 460

layout(local_size_x = 16, local_size_y = 16) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D image;

layout(push_constant) uniform PushConstants {
    vec4 data1;
    vec4 data2;
    vec4 data3;
    vec4 data4;
} push_constants;

void main()
{
    ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(image);

    vec4 top_color = push_constants.data1;
    vec4 bottom_color = push_constants.data2;

    if (texel_coord.x < size.x && texel_coord.y < size.y) {
        vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
        if (gl_LocalInvocationID.x != 0 && gl_LocalInvocationID.y != 0) {
            float blend = float(texel_coord.y) / float(size.y - 1);
            color = mix(top_color, bottom_color, blend);
        }

        imageStore(image, texel_coord, color);
    }
}

