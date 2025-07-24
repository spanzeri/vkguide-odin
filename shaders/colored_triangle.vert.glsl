#version 450

layout(location = 0) out vec3 out_color;

void main()
{
    const vec3 position[3] = vec3[3](
        vec3(-1.f, -1.f, 0.f),
        vec3( 1.f, -1.f, 0.f),
        vec3( 0.f,  1.f, 0.f)
    );

    const vec3 color[3] = vec3[3](
        vec3(1.f, 0.f, 0.f), // Red
        vec3(0.f, 1.f, 0.f), // Green
        vec3(0.f, 0.f, 1.f)  // Blue
    );

    gl_Position = vec4(position[gl_VertexIndex], 1.0);
    out_color = color[gl_VertexIndex];
}

