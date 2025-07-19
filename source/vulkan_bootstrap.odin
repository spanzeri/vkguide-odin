// This is a simple replacement for the Vulkan Bootstrap library in Odin.
package vkguide

import "base:runtime"
import "core:dynlib"
import "core:log"
import "core:mem"
import "core:strings"
import vk "vendor:vulkan"

//
// Library initialization (loading and unloading)
//

@(private="file")
g_vulkan_lib := dynlib.Library{}

@(init, private="file")

load_vulkan :: proc() {
    loaded :bool
    when ODIN_OS == .Windows {
        g_vulkan_lib, loaded = dynlib.load_library("vulkan-1.dll")
    } else when ODIN_OS == .Darwin {
        g_vulkan_lib, loaded = dynlib.load_library("libvulkan.dylib", true)
        if !loaded {
            g_vulkan_lib, loaded = dynlib.load_library("libvulkan.1.dylib", true)
        }
        if !loaded {
            g_vulkan_lib, loaded = dynlib.load_library("libMoltenVK.dylib", true)
        }
    } else {
        g_vulkan_lib, loaded = dynlib.load_library("libvulkan.so.1")
        if !loaded {
            g_vulkan_lib, loaded = dynlib.load_library("libvulkan.so")
        }
    }

    ensure(loaded, "Failed to load Vulkan library")
    ensure(g_vulkan_lib != nil, "Vulkan library handle is nil")

    vk_get_instance_proc_addresses, ok := dynlib.symbol_address(g_vulkan_lib, "vkGetInstanceProcAddr")
    ensure(vk_get_instance_proc_addresses != nil, "Failed to get vkGetInstanceProcAddr symbol")
    ensure(ok, "Failed to load vkGetInstanceProcAddr")

    vk.load_proc_addresses_global(vk_get_instance_proc_addresses)
}

@(fini, private="file")
unload_vulkan :: proc() {
    if g_vulkan_lib != nil {
        dynlib.unload_library(g_vulkan_lib)
        g_vulkan_lib = nil
    }
}

//
// Instance builder
//

Instance_Config :: struct {
    application_name:       string,
    engine_name:            string,
    application_version:    u32,
    engine_version:         u32,
    required_api_version:   u32,
    min_api_version:        u32,
    enable_validation:      bool,
    required_extensions:    []cstring,
}

vkbootstrap_init_instance_config :: proc() -> Instance_Config {
    return Instance_Config{
        application_name =      "",
        engine_name =           "no engine",
        application_version =   vk.MAKE_VERSION(1, 0, 0),
        engine_version =        vk.MAKE_VERSION(1, 0, 0),
        required_api_version =  vk.API_VERSION_1_0,
        min_api_version =       vk.API_VERSION_1_0,
        enable_validation =     ODIN_DEBUG,
        required_extensions =   []cstring{},
    }
}
vkbootstrap_create_instance :: proc(
    config: Instance_Config,
) -> (instance: vk.Instance, debug_messenger: vk.DebugUtilsMessengerEXT, ok: bool) {
    instance_api_version: u32 = 0
    vk_check(vk.EnumerateInstanceVersion(&instance_api_version)) or_return

    api_version := max(vk.API_VERSION_1_0, config.required_api_version, config.min_api_version)

    if api_version > vk.API_VERSION_1_0 && api_version > instance_api_version {
        log.errorf(
            "Vulkan API version is not supported. Required: %v.%v.%v. Available: %v.%v.%v.",
            _get_api_version_major(api_version),
            _get_api_version_minor(api_version),
            _get_api_version_patch(api_version),
            _get_api_version_major(instance_api_version),
            _get_api_version_minor(instance_api_version),
            _get_api_version_patch(instance_api_version),
        )
        return
    }

    app_info := vk.ApplicationInfo{
        sType              = .APPLICATION_INFO,
        pApplicationName   = strings.clone_to_cstring(config.application_name, context.temp_allocator),
        applicationVersion = config.application_version,
        pEngineName        = strings.clone_to_cstring(config.engine_name, context.temp_allocator),
        engineVersion      = config.engine_version,
        apiVersion         = api_version,
    }

    instance_create_info := vk.InstanceCreateInfo{
        sType                   = .INSTANCE_CREATE_INFO,
        pApplicationInfo        = &app_info,
        enabledLayerCount       = 0,
        ppEnabledLayerNames     = nil,
        enabledExtensionCount   = 0,
        ppEnabledExtensionNames = nil,
    }

    all_extensions :[]vk.ExtensionProperties
    all_extension_count := u32(0)
    vk_check(vk.EnumerateInstanceExtensionProperties(nil, &all_extension_count, nil)) or_return
    if all_extension_count > 0 {
        all_extensions = make_slice([]vk.ExtensionProperties, int(all_extension_count), context.temp_allocator)
        vk_check(vk.EnumerateInstanceExtensionProperties(nil, &all_extension_count, raw_data(all_extensions))) or_return
    }

    is_extension_supported :: proc(name: cstring, ext_props: []vk.ExtensionProperties) -> bool {
        for &ext in ext_props {
            if cstring(&ext.extensionName[0]) == name {
                return true
            }
        }
        return false
    }

    for ext in config.required_extensions {
        if !is_extension_supported(ext, all_extensions) {
            log.errorf("Required Vulkan extension '%s' is not supported by the instance.", ext)
            return
        }
    }

    layers := []cstring{ "VK_LAYER_KHRONOS_validation" }
    extensions := [dynamic]cstring{}

    enable_validation := config.enable_validation
    if enable_validation && !is_extension_supported(vk.EXT_DEBUG_UTILS_EXTENSION_NAME, all_extensions) {
        log.error(
            "VK_EXT_debug_utils extension is required for validation, but it's not supported. Disabling validation.")
        enable_validation = false

        layer_props : []vk.LayerProperties
        layer_count := u32(0)
        vk_check(vk.EnumerateInstanceLayerProperties(&layer_count, nil)) or_return
        if layer_count > 0 {
            layer_props = make_slice([]vk.LayerProperties, int(layer_count), context.temp_allocator)
            vk_check(vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layer_props))) or_return
        }

        for &layer in layer_props {
            if cstring(&layer.layerName[0]) == "VK_LAYER_KHRONOS_validation" {
                log.error("VK_LAYER_KHRONOS_validation is not supported by the instance. Disabling validation.")
                enable_validation = false
                break
            }
        }
    }

    if enable_validation || len(config.required_extensions) > 0 {
        cap := len(config.required_extensions) + 1
        extensions = make_dynamic_array_len_cap([dynamic]cstring, 0, cap, context.temp_allocator)
        if enable_validation {
            append_elem(&extensions, cstring("VK_EXT_debug_utils"))
        }
        for ext in config.required_extensions {
            append_elem(&extensions, ext)
        }
    }

    if enable_validation {
        instance_create_info.enabledLayerCount = u32(len(layers))
        instance_create_info.ppEnabledLayerNames = raw_data(layers)
    }
    instance_create_info.enabledExtensionCount = u32(len(extensions))
    instance_create_info.ppEnabledExtensionNames = raw_data(extensions)

    vk_check(vk.CreateInstance(&instance_create_info, nil, &instance)) or_return

    vk.load_proc_addresses_instance(instance)

    if enable_validation {
        _create_debug_messenger(instance, &debug_messenger) or_return
    }

    return instance, debug_messenger, true
}

//
// Physical Device selection
//

Physical_Device_Config :: struct {
    instance:               vk.Instance,
    surface:                vk.SurfaceKHR,
    min_api_version:        u32,
    required_extensions:    []cstring,
    required_features:      vk.PhysicalDeviceFeatures2,
}

Physical_Device :: struct {
    handle:                         vk.PhysicalDevice,
    graphics_queue_family_index:    u32,
    compute_queue_family_index:     u32,
    transfer_queue_family_index:    u32,
    present_queue_family_index:     u32,
    device_type:                    vk.PhysicalDeviceType,
    required_features:              vk.PhysicalDeviceFeatures2,
}

vkbootstrap_init_physical_device_config :: proc(
    instance: vk.Instance,
    surface: vk.SurfaceKHR = 0,
) -> Physical_Device_Config {
    return Physical_Device_Config{
        instance            = instance,
        surface             = surface,
        min_api_version     = vk.API_VERSION_1_0,
        required_extensions = []cstring{},
        required_features   = vk.PhysicalDeviceFeatures2{
            sType = .PHYSICAL_DEVICE_FEATURES_2,
        },
    }
}

vkbootstrap_set_physical_device_required_features_1_2 :: proc(
    config: ^Physical_Device_Config,
    features_1_2: ^vk.PhysicalDeviceVulkan12Features,
) {
    assert(config != nil, "Physical_Device_Config must not be nil")
    assert(features_1_2 != nil, "Physical_Device_Config must not be nil")
    features_1_2.sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    features_1_2.pNext = config.required_features.pNext
    config.required_features.pNext = features_1_2
}

vkbootstrap_set_physical_device_required_features_1_3 :: proc(
    config: ^Physical_Device_Config,
    features_1_3: ^vk.PhysicalDeviceVulkan13Features,
) {
    assert(config != nil, "Physical_Device_Config must not be nil")
    assert(features_1_3 != nil, "Physical_Device_Config must not be nil")
    features_1_3.sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    features_1_3.pNext = config.required_features.pNext
    config.required_features.pNext = features_1_3
}

vkbootstrap_select_physical_device :: proc(
    config: Physical_Device_Config,
) -> (physical_device: Physical_Device, ok: bool) {
    assert(config.instance != nil, "Vulkan instance must not be nil")

    physical_devices :[]vk.PhysicalDevice
    physical_device_count := u32(0)
    vk_check(vk.EnumeratePhysicalDevices(config.instance, &physical_device_count, nil)) or_return

    if physical_device_count == 0 {
        log.error("No Vulkan physical devices found")
        return
    }

    physical_devices = make_slice([]vk.PhysicalDevice, int(physical_device_count), context.temp_allocator)
    vk_check(
        vk.EnumeratePhysicalDevices(
            config.instance,
            &physical_device_count,
            raw_data(physical_devices),
        )) or_return


    required_api_version := max(vk.API_VERSION_1_0, config.min_api_version)

    best_physical_device := Physical_Device{}

    // Loop through all physical devices and check if they meet the requirements
    for curr_pd in physical_devices {
        props := vk.PhysicalDeviceProperties{}
        vk.GetPhysicalDeviceProperties(curr_pd, &props)

        // Test we match the api version
        if required_api_version > vk.API_VERSION_1_0 && props.apiVersion < required_api_version {
            log.infof(
                "Physical device '%s' does not support the required API version %v.%v.%v. Skipping.",
                cstring(&props.deviceName[0]),
                _get_api_version_major(required_api_version),
                _get_api_version_minor(required_api_version),
                _get_api_version_patch(required_api_version),
            )
            continue
        }

        // If we have a surface, check that the physical device supports presentation
        if config.surface != 0 {
            surface_capabilities := vk.SurfaceCapabilitiesKHR{}
            vk_check(
                vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
                    curr_pd,
                    config.surface,
                    &surface_capabilities,
                )) or_continue

            if surface_capabilities.supportedUsageFlags == {} {
                log.infof(
                    "Physical device '%s' does not support the required surface capabilities. Skipping.",
                    cstring(&props.deviceName[0]),
                )
                continue
            }
        }

        // Check if the physical device supports the required extensions
        if len(config.required_extensions) > 0 {
            available_extensions := []vk.ExtensionProperties{}
            available_extension_count := u32(0)
            vk_check(
                vk.EnumerateDeviceExtensionProperties(curr_pd, nil, &available_extension_count, nil)) or_continue

            if available_extension_count > 0 {
                available_extensions = make_slice([]vk.ExtensionProperties, int(available_extension_count), context.temp_allocator)
                vk_check(
                    vk.EnumerateDeviceExtensionProperties(
                        curr_pd,
                        nil,
                        &available_extension_count,
                        raw_data(available_extensions),
                    )) or_return
            }

            is_extension_supported :: proc(name: cstring, ext_props: []vk.ExtensionProperties) -> bool {
                for &ext in ext_props {
                    if cstring(&ext.extensionName[0]) == name {
                        return true
                    }
                }
                return false
            }

            for ext in config.required_extensions {
                if !is_extension_supported(ext, available_extensions) {
                    log.infof(
                        "Physical device '%s' does not support the required extension '%s'. Skipping.",
                        cstring(&props.deviceName[0]),
                        ext,
                    )
                    continue
                }
            }
        }

        // Check if the physical device supports the required features
        physical_device.required_features = config.required_features
        if !_check_physical_device_features(curr_pd, &physical_device.required_features) {
            log.infof(
                "Physical device '%s' does not support the required features. Skipping.",
                cstring(&props.deviceName[0]),
            )
            continue
        }

        // Find the queue families
        graphics_qfi, compute_qfi, transfer_qfi, present_qfi: u32
        graphics_qfi, compute_qfi, transfer_qfi, present_qfi, ok = _find_queue_family_indices(
            curr_pd,
            config.surface,
        )

        if !ok {
            log.infof(
                "Physical device '%s' does not support the required queue families. Skipping.",
                cstring(&props.deviceName[0]),
            )
            continue
        }

        if best_physical_device.handle == nil ||
           (props.deviceType == .DISCRETE_GPU && best_physical_device.handle != nil &&
            best_physical_device.device_type != .DISCRETE_GPU) ||
           (props.deviceType == .INTEGRATED_GPU && best_physical_device.handle != nil &&
            best_physical_device.device_type == .VIRTUAL_GPU) {
            // If we don't have a best physical device yet, or the current one is better, set it as the best
            best_physical_device = Physical_Device{
                handle                      = curr_pd,
                graphics_queue_family_index = graphics_qfi,
                compute_queue_family_index  = compute_qfi,
                transfer_queue_family_index = transfer_qfi,
                present_queue_family_index  = present_qfi,
                device_type                 = props.deviceType,
                required_features           = config.required_features,
            }
        }
    }

    return best_physical_device, best_physical_device.handle != nil
}

@(private = "file")
_check_physical_device_features :: proc(
    physical_device: vk.PhysicalDevice,
    required_features: ^vk.PhysicalDeviceFeatures2,
) -> bool {
    Base_Feature :: struct {
        sType: vk.StructureType,
        pNext: rawptr,
    }

    supported_features := vk.PhysicalDeviceFeatures2{
        sType = vk.StructureType.PHYSICAL_DEVICE_FEATURES_2,
    }

    // Allocate structures for the supported features that matches the required features
    supported_base := cast(^Base_Feature)(&supported_features)
    required_ptr := required_features.pNext
    outer: for required_ptr != nil {
        required_base_ptr := cast(^Base_Feature)required_ptr
        required_ptr = required_base_ptr.pNext

        alloc_err : runtime.Allocator_Error
        supported_base.pNext = _alloc_vulkan_feature_from_type(required_base_ptr.sType, context.temp_allocator)
        assert(alloc_err == .None)
        supported_base = cast(^Base_Feature)supported_base.pNext
        supported_base.sType = required_base_ptr.sType
    }

    // Query supported features from the physical device
    vk.GetPhysicalDeviceFeatures2(physical_device, &supported_features)

    compare_as_bytes :: proc(sup, req: []u8) -> bool {
        assert(len(req) == len(sup), "Feature byte slices must be of the same length")
        for i in 0..<len(req) {
            if req[i] > 0 && sup[i] == 0 {
                return false
            }
        }
        return true
    }

    if !compare_as_bytes(
        mem.ptr_to_bytes(&supported_features.features),
        mem.ptr_to_bytes(&required_features.features),
    ) {
        return false
    }

    to_byte_slice :: proc(base: ^Base_Feature, size: int) -> []u8 {
        slice := mem.slice_ptr(base, 2)
        return mem.slice_ptr(cast(^u8)(&slice[1]), size)
    }

    supported_base_ptr := cast(^Base_Feature)supported_features.pNext
    required_base_ptr := cast(^Base_Feature)required_features.pNext

    for required_base_ptr != nil && supported_base_ptr != nil {
        size_bytes := _get_vulkan_feature_size_of_from_type(required_base_ptr.sType) - size_of(Base_Feature)
        required_slice := to_byte_slice(required_base_ptr, size_bytes)
        supported_slice := to_byte_slice(supported_base_ptr, size_bytes)
        if !compare_as_bytes(supported_slice, required_slice) {
            return false
        }
        required_base_ptr = cast(^Base_Feature)required_base_ptr.pNext
        supported_base_ptr = cast(^Base_Feature)supported_base_ptr.pNext
    }

    assert(required_base_ptr == nil)
    assert(supported_base_ptr == nil)

    return true
}

@(private="file")
_find_queue_family_indices :: proc(
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
) -> (
    graphics_queue_family_index: u32,
    compute_queue_family_index: u32,
    transfer_queue_family_index: u32,
    present_queue_family_index: u32,
    ok: bool,
) {
    graphics_queue_family_index = vk.QUEUE_FAMILY_IGNORED
    compute_queue_family_index  = vk.QUEUE_FAMILY_IGNORED
    transfer_queue_family_index = vk.QUEUE_FAMILY_IGNORED
    present_queue_family_index  = vk.QUEUE_FAMILY_IGNORED

    queue_family_properties := []vk.QueueFamilyProperties{}
    queue_family_count := u32(0)
    vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, nil)
    if queue_family_count == 0 {
        log.error("No Vulkan queue families found")
        return
    }

    queue_family_properties = make_slice(
        []vk.QueueFamilyProperties,
        int(queue_family_count),
        context.temp_allocator,
    )

    vk.GetPhysicalDeviceQueueFamilyProperties(
        physical_device,
        &queue_family_count,
        raw_data(queue_family_properties),
    )

    for i in 0..<queue_family_count {
        family := queue_family_properties[i]

        if .GRAPHICS in family.queueFlags && graphics_queue_family_index == vk.QUEUE_FAMILY_IGNORED {
            graphics_queue_family_index = u32(i)
        }
        if .COMPUTE in family.queueFlags && compute_queue_family_index == vk.QUEUE_FAMILY_IGNORED {
            compute_queue_family_index = u32(i)
        }
        if .TRANSFER in family.queueFlags && transfer_queue_family_index == vk.QUEUE_FAMILY_IGNORED {
            transfer_queue_family_index = u32(i)
        }
        if surface != 0 && present_queue_family_index == vk.QUEUE_FAMILY_IGNORED {
            support_present :b32= false
            vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, u32(i), surface, &support_present)
            if support_present {
                present_queue_family_index = u32(i)
            }
        }

        if graphics_queue_family_index != vk.QUEUE_FAMILY_IGNORED &&
           compute_queue_family_index  != vk.QUEUE_FAMILY_IGNORED &&
           transfer_queue_family_index != vk.QUEUE_FAMILY_IGNORED &&
           present_queue_family_index  != vk.QUEUE_FAMILY_IGNORED {
            ok = true
            return
        }
    }

    return
}


//
// Device creation
//

Device_Config :: struct {
    physical_device:        Physical_Device,
    required_extensions:    []cstring,
}

vkbootstrap_init_device_config :: proc(physical_device: Physical_Device) -> Device_Config {
    return Device_Config{
        physical_device = physical_device,
        required_extensions = []cstring{},
    }
}

Device :: struct {
    handle: vk.Device,
    graphics_queue: vk.Queue,
    compute_queue:  vk.Queue,
    transfer_queue: vk.Queue,
    present_queue:  vk.Queue,
}

vkbootstrap_create_device :: proc(config: Device_Config) -> (device: Device, ok: bool) {
    assert(config.physical_device.handle != nil, "Physical device handle must not be nil")

    graphics_qi, compute_qi, transfer_qi, present_qi: u32
    queue_priority := f32(1)

    queue_create_infos: [4]vk.DeviceQueueCreateInfo
    queue_create_info_count := 0
    queue_create_infos[queue_create_info_count] = vk.DeviceQueueCreateInfo{
        sType            = .DEVICE_QUEUE_CREATE_INFO,
        queueFamilyIndex = config.physical_device.graphics_queue_family_index,
        queueCount       = 1,
        pQueuePriorities = &queue_priority,
    }
    graphics_qi = 0

    add_if_needed :: proc(
        queue_family_index: u32,
        queue_create_infos: ^[4]vk.DeviceQueueCreateInfo,
        queue_create_info_count: ^int,
        queue_priorities: ^f32,
    ) -> (index: u32) {
        for i in 0..<(queue_create_info_count^) {
            if queue_create_infos[i].queueFamilyIndex == queue_family_index {
                return u32(i)
            }
        }
        queue_create_infos[queue_create_info_count^] = vk.DeviceQueueCreateInfo{
            sType            = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = queue_family_index,
            queueCount       = 1,
            pQueuePriorities = queue_priorities,
        }
        index = u32(queue_create_info_count^)
        queue_create_info_count^ += 1
        return
    }

    compute_qi = add_if_needed(
        config.physical_device.compute_queue_family_index,
        &queue_create_infos,
        &queue_create_info_count,
        &queue_priority,
    )
    transfer_qi = add_if_needed(
        config.physical_device.transfer_queue_family_index,
        &queue_create_infos,
        &queue_create_info_count,
        &queue_priority,
    )
    present_qi = add_if_needed(
        config.physical_device.present_queue_family_index,
        &queue_create_infos,
        &queue_create_info_count,
        &queue_priority,
    )

    extensions, error := make_slice(
        []cstring,
        len(config.required_extensions) + 1,
        context.temp_allocator,
    )
    if error != .None {
        log.errorf("Failed to allocate device extensions: %v", error)
        return
    }

    for ext, i in config.required_extensions {
        extensions[i] = ext
    }
    extensions[len(config.required_extensions)] = vk.KHR_SWAPCHAIN_EXTENSION_NAME

    required_features := config.physical_device.required_features
    assert(required_features.sType == .PHYSICAL_DEVICE_FEATURES_2)

    device_create_info := vk.DeviceCreateInfo{
        sType                   = .DEVICE_CREATE_INFO,
        pNext                   = &required_features,
        queueCreateInfoCount    = u32(queue_create_info_count),
        pQueueCreateInfos       = raw_data(queue_create_infos[:queue_create_info_count]),
        enabledExtensionCount   = u32(len(extensions)),
        ppEnabledExtensionNames = raw_data(extensions),
    }

    if !vk_check(vk.CreateDevice(
        config.physical_device.handle,
        &device_create_info,
        nil,
        &device.handle,
    )) {
        log.error("Failed to create Vulkan device")
        return
    }

    vk.load_proc_addresses_device(device.handle)

    vk.GetDeviceQueue(
        device.handle,
        config.physical_device.graphics_queue_family_index,
        graphics_qi,
        &device.graphics_queue,
    )
    vk.GetDeviceQueue(
        device.handle,
        config.physical_device.compute_queue_family_index,
        compute_qi,
        &device.compute_queue,
    )
    vk.GetDeviceQueue(
        device.handle,
        config.physical_device.transfer_queue_family_index,
        transfer_qi,
        &device.transfer_queue,
    )
    vk.GetDeviceQueue(
        device.handle,
        config.physical_device.present_queue_family_index,
        present_qi,
        &device.present_queue,
    )

    return device, true
}

//
// Swapchain creation
//

Swapchain_Config :: struct {
    physical_device:             vk.PhysicalDevice,
    device:                      vk.Device,
    surface:                     vk.SurfaceKHR,
    graphics_queue_family_index: u32,
    present_queue_family_index:  u32,
    min_image_count:             u32,
    desired_format:              vk.SurfaceFormatKHR,
    desired_present_mode:        vk.PresentModeKHR,
    desired_extent:              vk.Extent2D,
    old_swapchain:               vk.SwapchainKHR,
}

vkbootstrap_init_swapchain_config :: proc(
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    surface: vk.SurfaceKHR,
    graphics_queue_family_index, present_queue_family_index: u32,
    width := u32(0),
    height := u32(0),
) -> Swapchain_Config {
    return Swapchain_Config{
        physical_device = physical_device,
        device = device,
        surface = surface,
        graphics_queue_family_index = graphics_queue_family_index,
        present_queue_family_index = present_queue_family_index,
        min_image_count = 2,
        desired_format = vk.SurfaceFormatKHR{
            format = .B8G8R8A8_SRGB,
            colorSpace = .SRGB_NONLINEAR,
        },
        desired_present_mode = .FIFO,
        desired_extent = vk.Extent2D{ width = 800, height = 600 },
        old_swapchain = 0,
    }
}

Swapchain :: struct {
    handle:                 vk.SwapchainKHR,
    image_count:            u32,
    format:                 vk.SurfaceFormatKHR,
    extent:                 vk.Extent2D,
    present_mode:           vk.PresentModeKHR,
    images:                 [dynamic]vk.Image,
    image_views:            [dynamic]vk.ImageView,
}

vkbootstrap_create_swapchain :: proc(
    config: Swapchain_Config,
    allocator := context.allocator,
) -> (swapchain: Swapchain, ok: bool) {
    assert(config.surface != 0, "Vulkan surface must not be nil")

    surface_capabilities := vk.SurfaceCapabilitiesKHR{}
    vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
        config.physical_device,
        config.surface,
        &surface_capabilities,
    )) or_return

    image_count := clamp(
        config.min_image_count,
        surface_capabilities.minImageCount,
        surface_capabilities.maxImageCount,
    )

    if image_count < config.min_image_count {
        log.errorf("Minimum image count %d is not supported by the surface. Using %d instead.",
            config.min_image_count, image_count)
        return
    }

    desired_extent := config.desired_extent
    if config.desired_extent.width > 0 && config.desired_extent.height > 0 {
        desired_extent.width = clamp(
            desired_extent.width,
            surface_capabilities.minImageExtent.width,
            surface_capabilities.maxImageExtent.width,
        )
        desired_extent.height = clamp(
            desired_extent.height,
            surface_capabilities.minImageExtent.height,
            surface_capabilities.maxImageExtent.height,
        )
    }

    if desired_extent.width == 0 || desired_extent.height == 0 {
        log.error("Desired swapchain extent is zero. Using current extent instead.")
        desired_extent = surface_capabilities.currentExtent
    }

    format: vk.SurfaceFormatKHR
    format, ok = _find_best_swapchain_format(
        config.physical_device,
        config.surface,
        config.desired_format,
    )
    if !ok {
        log.error("Failed to find a suitable swapchain format")
        return
    }

    present_mode: vk.PresentModeKHR
    present_mode, ok = _find_best_present_mode(
        config.physical_device,
        config.surface,
        config.desired_present_mode,
    )

    if !ok {
        log.error("Failed to find a suitable present mode")
        return
    }

    composite_alpha := vk.CompositeAlphaFlagsKHR{.OPAQUE}
    if .OPAQUE in surface_capabilities.supportedCompositeAlpha {
        composite_alpha = { .OPAQUE }
    } else if .INHERIT in surface_capabilities.supportedCompositeAlpha {
        composite_alpha = { .INHERIT }
    } else if .PRE_MULTIPLIED in surface_capabilities.supportedCompositeAlpha {
        composite_alpha = { .PRE_MULTIPLIED }
    } else if .POST_MULTIPLIED in surface_capabilities.supportedCompositeAlpha {
        composite_alpha = { .POST_MULTIPLIED }
    } else {
        log.error("No supported composite alpha mode found")
        return
    }


    swapchain_create_info := vk.SwapchainCreateInfoKHR{
        sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
        surface               = config.surface,
        minImageCount         = image_count,
        imageFormat           = format.format,
        imageColorSpace       = format.colorSpace,
        imageExtent           = desired_extent,
        imageArrayLayers      = 1,
        imageUsage            = { .COLOR_ATTACHMENT, .TRANSFER_DST },
        preTransform          = surface_capabilities.currentTransform,
        compositeAlpha        = composite_alpha,
        presentMode           = present_mode,
        clipped               = true,
        oldSwapchain          = config.old_swapchain,
    }

    // Determine the sharing mode and queue family indices
    if config.graphics_queue_family_index != config.present_queue_family_index {
        queue_family_indices := [2]u32{
            config.graphics_queue_family_index,
            config.present_queue_family_index,
        }
        swapchain_create_info.imageSharingMode = .CONCURRENT
        swapchain_create_info.queueFamilyIndexCount = 2
        swapchain_create_info.pQueueFamilyIndices = &queue_family_indices[0]
    } else {
        swapchain_create_info.imageSharingMode = .EXCLUSIVE
        swapchain_create_info.queueFamilyIndexCount = 0
        swapchain_create_info.pQueueFamilyIndices = nil
    }

    if !vk_check(vk.CreateSwapchainKHR(
        config.device,
        &swapchain_create_info,
        nil,
        &swapchain.handle,
    )) {
        log.error("Failed to create Vulkan swapchain")
        return
    }

    // This defer block ensures all the resources from now on are cleaned up if
    // any of the next operations fail.
    defer {
        if !ok {
            vk.DestroySwapchainKHR(config.device, swapchain.handle, nil)
            delete_dynamic_array(swapchain.images)
            delete_dynamic_array(swapchain.image_views)
        }
    }

    swapchain = Swapchain{
        handle       = swapchain.handle,
        image_count  = 0,
        format       = format,
        extent       = desired_extent,
        present_mode = present_mode,
        images       = [dynamic]vk.Image{},
        image_views  = [dynamic]vk.ImageView{},
    }

    // The swapchain is created at this point. We need to try and fetch the
    // images and create image views for them.
    // If any of the following operation fails, the defer block above will
    // destroy the swapchain and clean up resources.

    if !vk_check(vk.GetSwapchainImagesKHR(
        config.device,
        swapchain.handle,
        &swapchain.image_count,
        nil,
    )) {
        log.error("Failed to get swapchain images")
        return
    }

    if swapchain.image_count == 0 {
        log.error("No swapchain images found")
        return
    }

    error: runtime.Allocator_Error
    swapchain.images, error = make_dynamic_array_len(
        [dynamic]vk.Image,
        int(swapchain.image_count),
        allocator,
    )

    if error != .None {
        log.errorf("Failed to allocate swapchain images: %v", error)
        return
    }

    vk_check(vk.GetSwapchainImagesKHR(
        config.device,
        swapchain.handle,
        &swapchain.image_count,
        raw_data(swapchain.images),
    )) or_return

    swapchain.image_views, error = make_dynamic_array_len(
        [dynamic]vk.ImageView,
        int(swapchain.image_count),
        allocator,
    )

    if error != .None {
        log.errorf("Failed to allocate swapchain image views: %v", error)
        return
    }

    for i in 0..<swapchain.image_count {
        image_view_create_info := vk.ImageViewCreateInfo{
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = swapchain.images[i],
            viewType = .D2,
            format = format.format,
            components = vk.ComponentMapping{
                r = .IDENTITY,
                g = .IDENTITY,
                b = .IDENTITY,
                a = .IDENTITY,
            },
            subresourceRange = vk.ImageSubresourceRange{
                aspectMask     = { .COLOR },
                baseMipLevel   = 0,
                levelCount     = 1,
                baseArrayLayer = 0,
                layerCount     = 1,
            },
        }

        if !vk_check(vk.CreateImageView(
            config.device,
            &image_view_create_info,
            nil,
            &swapchain.image_views[i],
        )) {
            log.errorf("Failed to create image view for swapchain image %d", i)
            return
        }
    }

    return swapchain, true
}

@(private="file")
_find_best_swapchain_format :: proc(
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    desired_format: vk.SurfaceFormatKHR,
) -> (format: vk.SurfaceFormatKHR, ok: bool) {
    available_formats := []vk.SurfaceFormatKHR{}
    available_format_count := u32(0)

    vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        surface,
        &available_format_count,
        nil,
    )) or_return

    if available_format_count == 0 {
        log.error("No available surface formats found")
        return
    }

    available_formats = make_slice(
        []vk.SurfaceFormatKHR,
        int(available_format_count),
        context.temp_allocator,
    )
    vk_check(vk.GetPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        surface,
        &available_format_count,
        raw_data(available_formats),
    )) or_return

    if available_format_count  == 1 && available_formats[0].format == .UNDEFINED {
        // If the only available format is UNDEFINED, we can use the desired format
        return desired_format, true
    }

    best_format_found := available_formats[0]
    for fmt in available_formats {
        if fmt.format == desired_format.format {
            if fmt.colorSpace == desired_format.colorSpace {
                return fmt, true
            }
            if best_format_found.format == .UNDEFINED {
                best_format_found = fmt
            }
        }
    }

    return best_format_found, true
}

@(private="file")
_find_best_present_mode :: proc(
    physical_device: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    desired_present_mode: vk.PresentModeKHR,
) -> (present_mode: vk.PresentModeKHR, ok: bool) {
    available_present_modes := []vk.PresentModeKHR{}
    available_present_mode_count := u32(0)

    wants_vsync :=
        desired_present_mode == .FIFO || desired_present_mode == .FIFO_RELAXED

    vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(
        physical_device,
        surface,
        &available_present_mode_count,
        nil,
    )) or_return

    if available_present_mode_count == 0 {
        log.error("No available surface present modes found")
        return
    }

    available_present_modes = make_slice(
        []vk.PresentModeKHR,
        int(available_present_mode_count),
        context.temp_allocator,
    )

    vk_check(vk.GetPhysicalDeviceSurfacePresentModesKHR(
        physical_device,
        surface,
        &available_present_mode_count,
        raw_data(available_present_modes),
    )) or_return

    if available_present_mode_count == 1 {
        return available_present_modes[0], true
    }

    has_found_a_mode := false
    for mode in available_present_modes {
        if mode == desired_present_mode {
            return mode, true
        }

        // Save the first mode that matches the vsync requirement
        if mode != .FIFO && mode != .FIFO_RELAXED && !wants_vsync {
            present_mode = mode
            has_found_a_mode = true
        }
    }

    return present_mode, has_found_a_mode
}


//
// Private helpers
//

@(private="file")
g_logger : log.Logger

@(private="file")
_create_debug_messenger :: proc(
    instance: vk.Instance,
    debug_messenger: ^vk.DebugUtilsMessengerEXT,
) -> (ok: bool) {

    g_logger = context.logger

    callback :: proc "system"(
        message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
        message_type: vk.DebugUtilsMessageTypeFlagsEXT,
        p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
        p_user_data: rawptr,
    ) -> b32 {
        context = runtime.default_context()
        context.logger = g_logger

        severity_string := "UNKNOWN"
        switch {
        case .VERBOSE in message_severity: severity_string = "VERBOSE"
        case .INFO in message_severity:    severity_string = "INFO"
        case .WARNING in message_severity: severity_string = "WARNING"
        case .ERROR in message_severity:   severity_string = "ERROR"
        }

        type_strings := make_dynamic_array_len([dynamic]string, 0, context.temp_allocator)
        if .GENERAL in message_type                 { append_elem(&type_strings, "GENERAL")                }
        if .VALIDATION in message_type              { append_elem(&type_strings, "VALIDATION")             }
        if .PERFORMANCE in message_type             { append_elem(&type_strings, "PERFORMANCE")            }
        if .DEVICE_ADDRESS_BINDING in message_type  { append_elem(&type_strings, "DEVICE_ADDRESS_BINDING") }
        type_string := strings.join(type_strings[:], ", ", context.temp_allocator)

        log.debugf("Vulkan Debug Message: [%v][%v]\n%v", severity_string, type_string, p_callback_data.pMessage)

        assert(card(message_severity & {.ERROR, .WARNING }) == 0)

        return true
    }

    create_info := vk.DebugUtilsMessengerCreateInfoEXT{
        sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = { .VERBOSE, .INFO, .ERROR, .WARNING },
        messageType     = { .GENERAL, .VALIDATION, .PERFORMANCE },
        pfnUserCallback = callback,
        pUserData       = nil,
    }

    log.infof("Pointer: %p", vk.CreateDebugUtilsMessengerEXT)

    vk_check(vk.CreateDebugUtilsMessengerEXT(instance, &create_info, nil, debug_messenger)) or_return
    log.info("Vulkan Debug Messenger created successfully")

    return true
}

// Those functions are not part of the vk api in odin?
@(private = "file")
_get_api_version_major :: proc(version: u32) -> u32 {
    return (version >> 22) & 0x7F
}

@(private = "file")
_get_api_version_minor :: proc(version: u32) -> u32 {
    return (version >> 12) & 0x3FF
}

@(private = "file")
_get_api_version_patch :: proc(version: u32) -> u32 {
    return version & 0xFFF
}

@(private = "file")
_alloc_vulkan_feature_from_type :: proc(
    s_type: vk.StructureType,
    allocator := context.temp_allocator
) -> rawptr {
    res: rawptr = nil
    err: runtime.Allocator_Error

    #partial switch s_type {
    case .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES:
        res, err = mem.new(vk.PhysicalDeviceVulkan11Features, allocator)
    case .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES:
        res, err = mem.new(vk.PhysicalDeviceVulkan12Features, allocator)
    case .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES:
        res, err = mem.new(vk.PhysicalDeviceVulkan13Features, allocator)
    case .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES:
        res, err =mem.new(vk.PhysicalDeviceVulkan14Features, allocator)
    case:
        assert(false)
    }
    return res
}

@(private = "file")
_get_vulkan_feature_size_of_from_type :: proc(
    s_type: vk.StructureType,
) -> int {
    #partial switch s_type {
    case .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES:
        return size_of(vk.PhysicalDeviceVulkan11Features)
    case .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES:
        return size_of(vk.PhysicalDeviceVulkan12Features)
    case .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES:
        return size_of(vk.PhysicalDeviceVulkan13Features)
    case .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES:
        return size_of(vk.PhysicalDeviceVulkan14Features)
    case:
        assert(false)
    }
    return 0
}
