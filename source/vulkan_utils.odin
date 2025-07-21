package vkguide

import vk "vendor:vulkan"
import "core:os"
import "core:log"

load_shader_module :: proc(
    device: vk.Device,
    filepath: string,
    allocator := context.temp_allocator,
) -> (shader_module: vk.ShaderModule, ok: bool) {
    data: []byte
    data, ok = os.read_entire_file_from_filename(filepath, allocator)
    if !ok {
        log.errorf("Failed to read shader file: %s", filepath)
        return
    }

    if len(data) == 0 || len(data) % 4 != 0 {
        log.errorf("Shader file is empty or not aligned: %s", filepath)
        return
    }

    shader_module_create_info := vk.ShaderModuleCreateInfo{
        sType    = .SHADER_MODULE_CREATE_INFO,
        codeSize = len(data),
        pCode    = cast([^]u32)raw_data(data),
    }

    if !vk_check(
        vk.CreateShaderModule(device, &shader_module_create_info, nil, &shader_module),
    ) {
        log.errorf("Failed to create shader module from file: %s", filepath)
        return
    }

    return shader_module, true
}

