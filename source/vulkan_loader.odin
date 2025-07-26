package vkguide

import cgltf "vendor:cgltf"
import "core:strings"
import "core:log"
import la "core:math/linalg"

OVERRIDE_COLOR_WITH_NORMALS :: #config(OVERRIDE_MESH_COLOR_WITH_NORMALS, true)

Geo_Surface :: struct {
    start_index: u32,
    count:       u32,
}

Mesh_Asset :: struct {
    name:         string,
    surfaces:     [dynamic]Geo_Surface,
    mesh_buffers: Gpu_Mesh_Buffers,
}

loader_load_gltf_meshes :: proc(
    engine: ^Engine,
    file_path: string,
    temp_allocator := context.temp_allocator,
) -> (mesh_assets: [dynamic]Mesh_Asset, ok: bool) {
    options := cgltf.options{}

    cpath := strings.clone_to_cstring(file_path, temp_allocator)

    data, result := cgltf.parse_file(options, cpath)
    if result != .success {
        log.errorf("Failed to parse glTF file: %s", file_path)
        return
    }
    defer cgltf.free(data)

    result = cgltf.load_buffers(options, data, cpath)
    if result != .success {
        log.errorf("Failed to load buffers for glTF file: %s", file_path)
        return
    }

    vertices := make_dynamic_array_len_cap([dynamic]Vertex, 0, 256 * 1024, temp_allocator)
    indices := make_dynamic_array_len_cap([dynamic]u32, 0, 512 * 1024, temp_allocator)
    defer if !ok {
        delete_dynamic_array(vertices)
        delete_dynamic_array(indices)
    }

    // This would be better done per-node and store the matrix as well. But we'll
    // carry on following the tutorial structure for now.
    for mesh in data.meshes {
        if len(mesh.primitives) == 0 {
            continue
        }

        clear_dynamic_array(&vertices)
        clear_dynamic_array(&indices)
        surfaces := make_dynamic_array_len_cap([dynamic]Geo_Surface, 0, len(mesh.primitives))

        for primitive in mesh.primitives {
            if primitive.type != .triangles {
                log.errorf("Unsupported primitive type: %s", primitive.type)
                continue
            }

            surface := Geo_Surface{
                start_index = u32(len(indices)),
                count = u32(primitive.indices.count),
            }

            initial_vertex := len(vertices)
            first_index := len(indices)

            // Load indices
            {
                resize_dynamic_array(&indices, first_index + int(primitive.indices.count))
                if unpacked := cgltf.accessor_unpack_indices(
                    primitive.indices,
                    &indices[first_index],
                    size_of(u32),
                    primitive.indices.count,
                ); unpacked < uint(primitive.indices.count) {
                    log.errorf("Failed to unpack indices for primitive")
                    return
                }
            }

            position_index := -1
            normal_index := -1
            uv_index := -1
            color_index := -1
            vertex_count := uint(0)

            // Find accessors indices for the various attributes
            {
                for attrib, index in primitive.attributes {
                    if attrib.type == .position {
                        position_index = index
                    } else if attrib.type == .normal {
                        normal_index = index
                    } else if attrib.type == .texcoord && uv_index == -1 {
                        uv_index = index
                    } else if attrib.type == .color && color_index == -1 {
                        color_index = index
                    }
                }
            }

            if OVERRIDE_COLOR_WITH_NORMALS && color_index != -1 {
                // Don't load colors just for the sake of overriding them
                color_index = -1
            }

            if position_index == -1 {
                log.errorf("Mesh primitive has no position attribute")
                continue
            }

            position_attribute := primitive.attributes[position_index]
            vertex_count = position_attribute.data.count

            components := make_dynamic_array_len(
                [dynamic]f32,
                position_attribute.data.count * 3,
                temp_allocator)

            // Load vertices
            {
                assert(position_attribute.data.type == .vec3)

                _ = cgltf.accessor_unpack_floats(
                    position_attribute.data,
                    &components[0],
                    position_attribute.data.count * 3,
                )

                resize_dynamic_array(&vertices, initial_vertex + int(position_attribute.data.count))
                for vi in 0 ..< int(vertex_count) {
                    vertices[initial_vertex + vi] = Vertex{
                        position = Vec3{components[vi * 3 + 0], components[vi * 3 + 1], components[vi * 3 + 2]},
                        uv_x     = 0,
                        normal   = Vec3{0, 0, 0},
                        uv_y     = 0,
                        color    = Vec4{1, 1, 1, 1},
                    }
                }
            }

            // Load normals
            if normal_index != -1 {
                normal_attribute := primitive.attributes[normal_index]
                assert(normal_attribute.data.type == .vec3)
                assert(normal_attribute.data.count == vertex_count)

                _ = cgltf.accessor_unpack_floats(
                    normal_attribute.data,
                    &components[0],
                    normal_attribute.data.count * 3,
                )

                for vi in 0 ..< int(vertex_count) {
                    nml := Vec3{
                        components[vi * 3 + 0],
                        components[vi * 3 + 1],
                        components[vi * 3 + 2],
                    }
                    vertices[initial_vertex + vi].normal = la.normalize(nml)
                }
            } else {
                // Manually calculate normals if not provided
                for i := first_index; i < len(indices); i += 3 {
                    v0 := vertices[initial_vertex + int(indices[i + 0])]
                    v1 := vertices[initial_vertex + int(indices[i + 1])]
                    v2 := vertices[initial_vertex + int(indices[i + 2])]

                    edge1 := v1.position - v0.position
                    edge2 := v2.position - v0.position
                    normal := la.normalize(la.cross(edge1, edge2))

                    vertices[initial_vertex + int(indices[i + 0])].normal += normal
                    vertices[initial_vertex + int(indices[i + 1])].normal += normal
                    vertices[initial_vertex + int(indices[i + 2])].normal += normal
                }
            }

            // Load UVs
            if uv_index != -1 || primitive.attributes[uv_index].data.type == .vec2 {
                uv_attribute := primitive.attributes[uv_index]
                assert(uv_attribute.data.count == vertex_count)

                _ = cgltf.accessor_unpack_floats(
                    uv_attribute.data,
                    &components[0],
                    uv_attribute.data.count * 2,
                )

                for vi in 0 ..< int(vertex_count) {
                    vertices[initial_vertex + vi].uv_x = components[vi * 2 + 0]
                    vertices[initial_vertex + vi].uv_y = components[vi * 2 + 1]
                }
            }

            append_elem(&surfaces, surface)
        }

        if OVERRIDE_COLOR_WITH_NORMALS {
            for &v in vertices {
                color3 := (v.normal + 1.0) * 0.5
                v.color = Vec4{color3.x, color3.y, color3.z, 1.0}
            }
        }

        mesh_buffer: Gpu_Mesh_Buffers
        mesh_buffer, ok = engine_upload_mesh(engine, indices[:], vertices[:])
        if !ok {
            log.errorf("Failed to upload mesh buffers for mesh: %s", mesh.name)
            return
        }

        mesh_asset := Mesh_Asset{
            name = strings.clone_from_cstring(mesh.name),
            surfaces = surfaces,
            mesh_buffers = mesh_buffer,
        }

        append_elem(&mesh_assets, mesh_asset)
    }

    return mesh_assets, true
}

destroy_mesh_asset :: proc(engine: ^Engine, mesh_asset: ^Mesh_Asset) {
    if mesh_asset == nil {
        return
    }

    destroy_buffer(engine.allocator, &mesh_asset.mesh_buffers.vertex_buffer)
    destroy_buffer(engine.allocator, &mesh_asset.mesh_buffers.index_buffer)
    mesh_asset.mesh_buffers.vertex_buffer_address = 0
    delete(mesh_asset.name)
    delete_dynamic_array(mesh_asset.surfaces)
}

