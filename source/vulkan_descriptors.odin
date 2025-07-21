package vkguide

import vk "vendor:vulkan"

Descriptor_Layout_Builder :: struct {
    bindings: [dynamic]vk.DescriptorSetLayoutBinding,
}

descriptor_layout_builder_init :: proc(allocator := context.temp_allocator) -> Descriptor_Layout_Builder {
    return Descriptor_Layout_Builder{
        bindings = make_dynamic_array_len_cap(
            [dynamic]vk.DescriptorSetLayoutBinding,
            0,
            16,
            allocator,
        ),
    }
}

descriptor_layout_builder_destroy :: proc(self: ^Descriptor_Layout_Builder) {
    delete_dynamic_array(self.bindings)
}

descriptor_layout_builder_add_binding :: proc(
    self: ^Descriptor_Layout_Builder,
    binding: u32,
    type: vk.DescriptorType,
) {
    set_layout_binding := vk.DescriptorSetLayoutBinding{
        binding = binding,
        descriptorType = type,
        descriptorCount = 1,
    }

    append_elem(&self.bindings, set_layout_binding)
}

descriptor_layout_builder_clear :: proc(self: ^Descriptor_Layout_Builder) {
    clear_dynamic_array(&self.bindings)
}

descriptor_layout_builder_build :: proc(
    self: ^Descriptor_Layout_Builder,
    device: vk.Device,
    shader_stages: vk.ShaderStageFlags,
    next: rawptr = nil,
    flags: vk.DescriptorSetLayoutCreateFlags = {},
) -> vk.DescriptorSetLayout {
    for &binding in self.bindings {
        binding.stageFlags  = shader_stages
    }

    info := vk.DescriptorSetLayoutCreateInfo{
        sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        pNext        = next,
        pBindings    = raw_data(self.bindings),
        bindingCount = u32(len(self.bindings)),
    }

    set: vk.DescriptorSetLayout
    if vk.CreateDescriptorSetLayout(device, &info, nil, &set) != .SUCCESS {
        assert(false, "Failed to create descriptor set layout")
    }
    return set
}

Pool_Size_Ratio :: struct {
    type: vk.DescriptorType,
    ratio: f32,
}

descriptor_pool_init :: proc(
    device: vk.Device,
    max_sets: u32,
    pool_ratios: []Pool_Size_Ratio,
    allocator := context.temp_allocator,
) -> vk.DescriptorPool {
    sizes, err := make_slice([]vk.DescriptorPoolSize, len(pool_ratios), allocator)
    assert(err == .None)
    defer delete_slice(sizes, allocator)

    for ratio, i in pool_ratios {
        sizes[i] = vk.DescriptorPoolSize{
            type = ratio.type,
            descriptorCount = u32(f32(max_sets) * ratio.ratio),
        }
    }

    pool_info := vk.DescriptorPoolCreateInfo{
        sType = .DESCRIPTOR_POOL_CREATE_INFO,
        flags = {},
        maxSets = max_sets,
        poolSizeCount = u32(len(pool_ratios)),
        pPoolSizes = raw_data(sizes),
    }

    pool: vk.DescriptorPool
    res := vk.CreateDescriptorPool(device, &pool_info, nil, &pool)
    assert(res == .SUCCESS)
    return pool
}

descriptor_pool_clear_descriptors :: proc(self: vk.DescriptorPool, device: vk.Device) {
    vk.ResetDescriptorPool(device, self, {})
}

descriptor_pool_destroy :: proc(self: vk.DescriptorPool, device: vk.Device) {
    if self != 0 {
        vk.DestroyDescriptorPool(device, self, nil)
    }
}

descriptor_pool_allocate :: proc(
    self: vk.DescriptorPool,
    device: vk.Device,
    layout: vk.DescriptorSetLayout,
) -> vk.DescriptorSet {
    llayout := layout
    alloc_info := vk.DescriptorSetAllocateInfo{
        sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = self,
        descriptorSetCount = 1,
        pSetLayouts = &llayout,
    }

    ds: vk.DescriptorSet
    res := vk.AllocateDescriptorSets(device, &alloc_info, &ds)
    assert(res == .SUCCESS)

    return ds
}

