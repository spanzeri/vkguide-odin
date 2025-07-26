package vkguide

import "base:runtime"
import "core:mem"
import vk "vendor:vulkan"

//======================================
//
// Growable Descriptor Set Allocator
//
//======================================

Pool_Size_Ratio :: struct {
    type:  vk.DescriptorType,
    ratio: f32,
}

Descriptor_Growable_Allocator :: struct {
    ratios:         [dynamic]Pool_Size_Ratio,
    full_pools:     [dynamic]vk.DescriptorPool,
    ready_pools:    [dynamic]vk.DescriptorPool,
    sets_per_pool:  i32,
    device:         vk.Device,
}

descriptor_growable_allocator_init :: proc(
    device: vk.Device,
    max_sets: i32,
    pool_ratios: []Pool_Size_Ratio,
    allocator := context.allocator,
) -> (res: Descriptor_Growable_Allocator, ok: bool) {
    assert(len(pool_ratios) > 0, "Pool ratios must not be empty")
    assert(max_sets > 0, "Max sets must be greater than 0")

    defer if !ok {
        delete_dynamic_array(res.ratios)
        delete_dynamic_array(res.full_pools)
        delete_dynamic_array(res.ready_pools)
    }

    err :runtime.Allocator_Error
    res.ratios, err = make_dynamic_array_len([dynamic]Pool_Size_Ratio, len(pool_ratios), allocator)
    if err != .None { return }
    mem.copy(raw_data(res.ratios), raw_data(pool_ratios), len(pool_ratios) * size_of(Pool_Size_Ratio))
    res.full_pools, err = make_dynamic_array_len_cap([dynamic]vk.DescriptorPool, 0, 16, allocator)
    if err != .None { return }
    res.ready_pools, err = make_dynamic_array_len_cap([dynamic]vk.DescriptorPool, 0, 16, allocator)
    if err != .None { return }
    res.sets_per_pool = max_sets
    res.device = device

    return res, true
}

descriptor_growable_allocator_destroy :: proc(self: ^Descriptor_Growable_Allocator) {
    descriptor_growable_allocator_destroy_pools(self)
    delete_dynamic_array(self.ratios)
    delete_dynamic_array(self.full_pools)
    delete_dynamic_array(self.ready_pools)
}

descriptor_growable_allocator_get_pool :: proc(
    self: ^Descriptor_Growable_Allocator,
) -> vk.DescriptorPool {
    new_pool :vk.DescriptorPool
    if len(self.ready_pools) > 0 {
        new_pool = pop(&self.ready_pools)
    } else {
        ok: bool
        new_pool, ok = _create_pool(self)
        assert(ok, "Failed to create descriptor pool")
        self.sets_per_pool = min(self.sets_per_pool, 8)
        self.sets_per_pool = self.sets_per_pool + (self.sets_per_pool >> 1)
        self.sets_per_pool = min(self.sets_per_pool, 4096)
    }

    return new_pool
}

descriptor_growable_allocator_allocate :: proc(
    self: ^Descriptor_Growable_Allocator,
    layout: vk.DescriptorSetLayout,
) -> vk.DescriptorSet {
    pool := descriptor_growable_allocator_get_pool(self)
    llayout := layout
    alloc_info := vk.DescriptorSetAllocateInfo{
        sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool     = pool,
        descriptorSetCount = 1,
        pSetLayouts        = &llayout,
    }
    ds: vk.DescriptorSet
    res := vk.AllocateDescriptorSets(self.device, &alloc_info, &ds)
    if res == .ERROR_OUT_OF_POOL_MEMORY  || res == .ERROR_FRAGMENTED_POOL {
        append_elem(&self.full_pools, pool)
        pool_to_use := descriptor_growable_allocator_get_pool(self)
        alloc_info.descriptorPool = pool_to_use
        res = vk.AllocateDescriptorSets(self.device, &alloc_info, &ds)
        assert(res == .SUCCESS)
    }

    append_elem(&self.ready_pools, pool)
    return ds
}

descriptor_growable_allocator_clear_pools :: proc(self: ^Descriptor_Growable_Allocator) {
    for pool in self.ready_pools {
        vk.ResetDescriptorPool(self.device, pool, {})
    }
    for pool in self.full_pools {
        vk.ResetDescriptorPool(self.device, pool, {})
        append_elem(&self.ready_pools, pool)
    }
    clear_dynamic_array(&self.full_pools)
}

descriptor_growable_allocator_destroy_pools :: proc(self: ^Descriptor_Growable_Allocator) {
    for pool in self.ready_pools {
        vk.DestroyDescriptorPool(self.device, pool, nil)
    }
    for pool in self.full_pools {
        vk.DestroyDescriptorPool(self.device, pool, nil)
    }
    clear_dynamic_array(&self.ready_pools)
    clear_dynamic_array(&self.full_pools)
}

//======================================
//
// Descriptor_Writer
//
//======================================

Descriptor_Writer :: struct {
    buffer_infos:       [16]vk.DescriptorBufferInfo,
    image_infos:        [16]vk.DescriptorImageInfo,
    writes:             [32]vk.WriteDescriptorSet,
    buffer_info_count:  u32,
    image_info_count:   u32,
    write_count:        u32,
}

descriptor_writer_write_buffer :: proc(
    self: ^Descriptor_Writer,
    binding: u32,
    buffer: vk.Buffer,
    size: u64,
    offset: u64 = 0,
    type: vk.DescriptorType = .STORAGE_BUFFER,
) {
    assert(self.buffer_info_count < len(self.buffer_infos))
    assert(self.write_count < len(self.writes))
    assert(
        type == .UNIFORM_BUFFER || type == .STORAGE_BUFFER ||
        type == .UNIFORM_BUFFER_DYNAMIC || type == .STORAGE_BUFFER_DYNAMIC,
    )

    self.buffer_infos[self.buffer_info_count] = vk.DescriptorBufferInfo{
        buffer = buffer,
        offset = vk.DeviceSize(offset),
        range  = vk.DeviceSize(size),
    }
    self.buffer_info_count += 1

    self.writes[self.write_count] = vk.WriteDescriptorSet{
        sType           = .WRITE_DESCRIPTOR_SET,
        dstBinding      = binding,
        descriptorCount = 1,
        descriptorType  = type,
        pBufferInfo     = &self.buffer_infos[self.buffer_info_count - 1],
    }
    self.write_count += 1
}

descriptor_writer_write_image :: proc(
    self: ^Descriptor_Writer,
    binding: u32,
    image_view: vk.ImageView,
    sampler: vk.Sampler,
    layout: vk.ImageLayout = .SHADER_READ_ONLY_OPTIMAL,
    type: vk.DescriptorType = .COMBINED_IMAGE_SAMPLER,
) {
    assert(self.image_info_count < len(self.image_infos))
    assert(self.write_count < len(self.writes))

    self.image_infos[self.image_info_count] = vk.DescriptorImageInfo{
        sampler     = sampler,
        imageView   = image_view,
        imageLayout = layout,
    }
    self.image_info_count += 1

    self.writes[self.write_count] = vk.WriteDescriptorSet{
        sType           = .WRITE_DESCRIPTOR_SET,
        dstBinding      = binding,
        descriptorCount = 1,
        descriptorType  = type,
        pImageInfo      = &self.image_infos[self.image_info_count - 1],
    }
    self.write_count += 1
}

descriptor_writer_clear :: proc(self: ^Descriptor_Writer) {
    self.buffer_info_count = 0
    self.image_info_count = 0
    self.write_count = 0
}

descriptor_writer_update_set :: proc(self: ^Descriptor_Writer, device: vk.Device, set: vk.DescriptorSet) {
    if self.write_count == 0 { return }

    for i in 0 ..< self.write_count {
        self.writes[i].dstSet = set
    }

    vk.UpdateDescriptorSets(device, self.write_count, &self.writes[0], 0, nil)
}

//======================================
//
// Descriptor_Layout_Builder
//
//======================================

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

@(private="file")
_create_pool :: proc(
    self: ^Descriptor_Growable_Allocator,
) -> (pool: vk.DescriptorPool, ok: bool) {
    pool_size := make_slice([]vk.DescriptorPoolSize, len(self.ratios), context.temp_allocator)
    for ratio, i in self.ratios {
        pool_size[i] = vk.DescriptorPoolSize{
            type = ratio.type,
            descriptorCount = min(1, u32(f32(self.sets_per_pool) * ratio.ratio)),
        }
    }

    pool_info := vk.DescriptorPoolCreateInfo{
        sType         = .DESCRIPTOR_POOL_CREATE_INFO,
        maxSets       = u32(self.sets_per_pool),
        poolSizeCount = u32(len(self.ratios)),
        pPoolSizes    = raw_data(pool_size),
    }

    res := vk.CreateDescriptorPool(self.device, &pool_info, nil, &pool)
    if res != .SUCCESS {
        assert(false, "Failed to create descriptor pool")
        return
    }
    return pool, true
}

