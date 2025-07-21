#version 460

layout(local_size_x = 16, local_size_y = 16) in;
layout(rgba16f, set = 0, binding = 0) uniform image2D image;

void main()
{
    ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(image);

    if (texel_coord.x < size.x && texel_coord.y < size.y) {
        vec4 color = vec4(0.0, 0.0, 0.0, 1.0);
        if (gl_LocalInvocationID.x != 0 && gl_LocalInvocationID.y != 0) {
            color.x = float(texel_coord.x) / size.x;
            color.y = float(texel_coord.y) / size.y;
        }

        imageStore(image, texel_coord, color);
    }
}

