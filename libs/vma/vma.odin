package vma

when ODIN_OS == .Linux {
    @(require, extra_linker_flags="-lstdc++") foreign import stdcpp "system:c++"
}

when ODIN_OS == .Linux {
    foreign import _vma_lib_ "../../build/libvma-3.3.0.a"
} else {
    #assert(false, "TODO port")
}

import vk "vendor:vulkan"

Allocator :: distinct rawptr
Allocation :: distinct rawptr
Pool :: distinct rawptr

Flags :: distinct u32

Allocator_Create_Flag :: enum Flags {
    ExternallySynchronized  = 0,
    KHRDedicatedAllocation  = 1,
    KHRBindMemory2          = 2,
    ExtMemoryBudget         = 3,
    AmdDeviceCoherentMemory = 4,
    BufferDeviceAddress     = 5,
    ExtMemoryPriority       = 6,
    KHRMaintenance4         = 7,
    KHRMaintenance5         = 8,
    KHRExternalMemoryWin32  = 9,
}

Allocator_Create_Flags :: distinct bit_set[Allocator_Create_Flag; Flags]

Allocator_Create_Info :: struct {
    flags:                              Allocator_Create_Flags,
    physical_device:                    vk.PhysicalDevice,
    device:                             vk.Device,
    preferred_large_heap_block_size:    vk.DeviceSize,
    allocation_callbacks:               ^vk.AllocationCallbacks,
    device_memory_callbacks:            ^Device_Memory_Callbacks,
    heap_size_limit:                    [^]vk.DeviceSize,
    vulkan_functions:                   ^Vulkan_Functions,
    instance:                           vk.Instance,
    vulkan_api_version:                 u32,
    type_external_memory_handle_types:  [^]vk.ExternalMemoryHandleTypeFlags,
}

Device_Memory_Callbacks :: struct {
    pfn_allocate:   Allocate_Device_Memory_Function,
    pfn_free:       Free_Device_Memory_Function,
    p_user_data:    rawptr,
}

Allocate_Device_Memory_Function :: #type proc "c" (
    allocator:      Allocator,
    memory_type:    u32,
    memory:         vk.DeviceMemory,
    size:           vk.DeviceSize,
    p_user_data:    rawptr,
)

Free_Device_Memory_Function :: #type proc "c" (
    allocator:      Allocator,
    memory_type:    u32,
    memory:         vk.DeviceMemory,
    size:           vk.DeviceSize,
    p_user_data:    rawptr,
)

Vulkan_Functions :: struct {
    _unused_1:                                  proc(), // vk.ProcGetInstanceProcAddr
    _unused_2:                                  proc(), // vk.ProcGetDeviceProcAddr
    get_physical_device_properties:             vk.ProcGetPhysicalDeviceProperties,
    get_physical_device_memory_properties:      vk.ProcGetPhysicalDeviceMemoryProperties,
    allocate_memory:                            vk.ProcAllocateMemory,
    free_memory:                                vk.ProcFreeMemory,
    map_memory:                                 vk.ProcMapMemory,
    unmap_memory:                               vk.ProcUnmapMemory,
    flush_mapped_memory_ranges:                 vk.ProcFlushMappedMemoryRanges,
    invalidate_mapped_memory_ranges:            vk.ProcInvalidateMappedMemoryRanges,
    bind_buffer_memory:                         vk.ProcBindBufferMemory,
    bind_image_memory:                          vk.ProcBindImageMemory,
    get_buffer_memory_requirements:             vk.ProcGetBufferMemoryRequirements,
    get_image_memory_requirements:              vk.ProcGetImageMemoryRequirements,
    create_buffer:                              vk.ProcCreateBuffer,
    destroy_buffer:                             vk.ProcDestroyBuffer,
    create_image:                               vk.ProcCreateImage,
    destroy_image:                              vk.ProcDestroyImage,
    cmd_copy_buffer:                            vk.ProcCmdCopyBuffer,
    get_buffer_memory_requirements2_khr:        vk.ProcGetBufferMemoryRequirements2KHR,
    get_image_memory_requirements2_khr:         vk.ProcGetImageMemoryRequirements2KHR,
    bind_buffer_memory2_khr:                    vk.ProcBindBufferMemory2KHR,
    bind_image_memory2_khr:                     vk.ProcBindImageMemory2KHR,
    get_physical_device_memory_properties2_khr: vk.ProcGetPhysicalDeviceMemoryProperties2KHR,
    get_device_buffer_memory_requirements:      vk.ProcGetDeviceBufferMemoryRequirementsKHR,
    get_device_image_memory_requirements:       vk.ProcGetDeviceImageMemoryRequirementsKHR,
    get_memory_win32_handle_khr:                vk.ProcGetMemoryWin32HandleKHR,
}

Allocation_Info :: struct {
    memory_type:   u32,
    device_memory: vk.DeviceMemory,
    offset:        vk.DeviceSize,
    size:          vk.DeviceSize,
    mapped_data:   rawptr,
    user_data:     rawptr,
    name:          cstring,
}

Allocation_Create_Info :: struct {
    flags:              Allocation_Create_Flags,
    usage:              Memory_Usage,
    required_flags:     vk.MemoryPropertyFlags,
    preferred_flags:    vk.MemoryPropertyFlags,
    memory_type_bits:   u32,
    pool:               Pool,
    user_data:          rawptr,
    priority:           f32,
}

create_vulkan_functions :: proc() -> Vulkan_Functions {
    return Vulkan_Functions{
        _unused_1                                  = nil,
        _unused_2                                  = nil,
        get_physical_device_properties             = vk.GetPhysicalDeviceProperties,
        get_physical_device_memory_properties      = vk.GetPhysicalDeviceMemoryProperties,
        allocate_memory                            = vk.AllocateMemory,
        free_memory                                = vk.FreeMemory,
        map_memory                                 = vk.MapMemory,
        unmap_memory                               = vk.UnmapMemory,
        flush_mapped_memory_ranges                 = vk.FlushMappedMemoryRanges,
        invalidate_mapped_memory_ranges            = vk.InvalidateMappedMemoryRanges,
        bind_buffer_memory                         = vk.BindBufferMemory,
        bind_image_memory                          = vk.BindImageMemory,
        get_buffer_memory_requirements             = vk.GetBufferMemoryRequirements,
        get_image_memory_requirements              = vk.GetImageMemoryRequirements,
        create_buffer                              = vk.CreateBuffer,
        destroy_buffer                             = vk.DestroyBuffer,
        create_image                               = vk.CreateImage,
        destroy_image                              = vk.DestroyImage,
        cmd_copy_buffer                            = vk.CmdCopyBuffer,
        get_buffer_memory_requirements2_khr        = vk.GetBufferMemoryRequirements2KHR,
        get_image_memory_requirements2_khr         = vk.GetImageMemoryRequirements2KHR,
        bind_buffer_memory2_khr                    = vk.BindBufferMemory2KHR,
        bind_image_memory2_khr                     = vk.BindImageMemory2KHR,
        get_physical_device_memory_properties2_khr = vk.GetPhysicalDeviceMemoryProperties2KHR,
        get_device_buffer_memory_requirements      = vk.GetDeviceBufferMemoryRequirementsKHR,
        get_device_image_memory_requirements       = vk.GetDeviceImageMemoryRequirementsKHR,
        get_memory_win32_handle_khr                = vk.GetMemoryWin32HandleKHR,
    }
}

Allocation_Create_Flags :: distinct bit_set[Allocation_Create_Flag; Flags]
Allocation_Create_Flag :: enum Flags {
    DEDICATED_MEMORY                   = 0,
    NEVER_ALLOCATE                     = 1,
    MAPPED                             = 2,
    USER_DATA_COPY_STRING              = 5,
    UPPER_ADDRESS                      = 6,
    DONT_BIND                          = 7,
    WITHIN_BUDGET                      = 8,
    CAN_ALIAS                          = 9,
    HOST_ACCESS_SEQUENTIAL_WRITE       = 10,
    HOST_ACCESS_RANDOM                 = 11,
    HOST_ACCESS_ALLOW_TRANSFER_INSTEAD = 12,
    STRATEGY_MIN_MEMORY                = 16,
    STRATEGY_MIN_TIME                  = 17,
    STRATEGY_MIN_OFFSET                = 18,
    STRATEGY_BEST_FIT                  = STRATEGY_MIN_MEMORY,
    STRATEGY_FIRST_FIT                 = STRATEGY_MIN_TIME,
}

Memory_Usage :: enum u32 {
    UNKNOWN              = 0,
    GPU_ONLY             = 1,
    CPU_ONLY             = 2,
    CPU_TO_GPU           = 3,
    GPU_TO_CPU           = 4,
    CPU_COPY             = 5,
    GPU_LAZILY_ALLOCATED = 6,
    AUTO                 = 7,
    AUTO_PREFER_DEVICE   = 8,
    AUTO_PREFER_HOST     = 9,
}

@(default_calling_convention="c")
foreign _vma_lib_ {
    @(link_name="vmaCreateAllocator")
    create_allocator :: proc(
        #by_ptr create_info: Allocator_Create_Info,
        allocator: ^Allocator,
    ) -> vk.Result ---

    @(link_name="vmaDestroyAllocator")
    destroy_allocator :: proc(allocator: Allocator) -> vk.Result ---

    @(link_name="vmaCreateImage")
    create_image :: proc(
        allocator: Allocator,
        #by_ptr image_create_info: vk.ImageCreateInfo,
        #by_ptr allocation_create_info: Allocation_Create_Info,
        image: ^vk.Image,
        allocation: ^Allocation,
        allocation_info: ^Allocation_Info,
    ) -> vk.Result ---

    @(link_name="vmaDestroyImage")
    destroy_image :: proc(
        allocator: Allocator,
        image: vk.Image,
        allocation: Allocation,
    ) -> vk.Result ---

    @(link_name="vmaCreateBuffer")
    create_buffer :: proc(
        allocator: Allocator,
        #by_ptr buffer_create_info: vk.BufferCreateInfo,
        #by_ptr allocation_create_info: Allocation_Create_Info,
        buffer: ^vk.Buffer,
        allocation: ^Allocation,
        allocation_info: ^Allocation_Info,
    ) -> vk.Result ---

    @(link_name="vmaDestroyBuffer")
    destroy_buffer :: proc(
        allocator: Allocator,
        buffer: vk.Buffer,
        allocation: Allocation,
    ) -> vk.Result ---
}

