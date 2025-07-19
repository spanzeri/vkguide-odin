package vkguide

import "core:log"
import "core:time"

import sdl "vendor:sdl3"
import vk "vendor:vulkan"

VulkanEngine :: struct {
    window:                             ^sdl.Window,
    minimized:                          bool,

    window_extent:                      struct {
        width:  u32,
        height: u32,
    },

    instance:                           vk.Instance,
    debug_messenger:                    vk.DebugUtilsMessengerEXT,

    surface:                            vk.SurfaceKHR,
    physical_device:                    vk.PhysicalDevice,

    physical_device_properties:         vk.PhysicalDeviceProperties,
    physical_device_features:           vk.PhysicalDeviceFeatures,
    physical_device_memory_properties:  vk.PhysicalDeviceMemoryProperties,

    device:                             vk.Device,

    graphics_queue_family_index:        u32,
    present_queue_family_index:         u32,
    compute_queue_family_index:         u32,
    transfer_queue_family_index:        u32,
    graphics_queue:                     vk.Queue,
    present_queue:                      vk.Queue,
    compute_queue:                      vk.Queue,
    transfer_queue:                     vk.Queue,

    swapchain:                          vk.SwapchainKHR,
    swapchain_images:                   [dynamic]vk.Image,
    swapchain_image_views:              [dynamic]vk.ImageView,
    swapchain_extent:                   vk.Extent2D,
}

Engine_Init_Options :: struct {
    title:          string,
    window_size:    Vec2i,
}

@(require_results)
engine_init :: proc(
    self: ^VulkanEngine,
    opts: Engine_Init_Options = {
        title = "Vulkan Engine",
        window_size = Vec2i{1024, 768},
    },
) -> (ok: bool) {
    assert(self != nil, "VulkanEngine cannot be nil")
    assert(self.window == nil, "VulkanEngine window must be nil on initialization")

    if !sdl.Init(sdl.INIT_VIDEO) {
        log.error("Failed to initialize SDL: %v", sdl.GetError())
        return false
    }

    self.window = sdl.CreateWindow("Vulkan Engine", 1024, 768, sdl.WINDOW_VULKAN)
    if self.window == nil {
        log.error("Failed to create SDL window: %s", sdl.GetError())
        return false
    }

    ww, wh: i32
    sdl.GetWindowSizeInPixels(self.window, &ww, &wh)
    self.window_extent.width = u32(ww)
    self.window_extent.height = u32(wh)

    if !_init_vulkan(self) {
        log.error("Failed to create Vulkan instance")
        return false
    }

    if !_init_swapchain(self) {
        log.error("Failed to initialize Vulkan swapchain")
        return false
    }

    return true
}

engine_shutdown :: proc(self: ^VulkanEngine) {
    _destroy_swapchain(self)

    if self.device != nil {
        vk.DestroyDevice(self.device, nil)
        self.device = nil
    }

    if self.surface != 0 {
        vk.DestroySurfaceKHR(self.instance, self.surface, nil)
        self.surface = 0
    }

    if self.debug_messenger != 0 {
        vk.DestroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, nil)
        self.debug_messenger = 0
    }

    if self.instance != nil {
        vk.DestroyInstance(self.instance, nil)
        self.instance = nil
    }

    if self.window != nil {
        sdl.DestroyWindow(self.window)
        self.window = nil
    }

    sdl.Quit()
}

engine_run :: proc(self: ^VulkanEngine) {
    for {
        free_all(context.temp_allocator)

        event := sdl.Event{}
        for sdl.PollEvent(&event) {
            #partial switch event.type {
            case .QUIT, .WINDOW_CLOSE_REQUESTED:
                return
            case .WINDOW_MINIMIZED:
                self.minimized = true
            case .WINDOW_RESTORED:
                self.minimized = false
            }
        }

        if self.minimized {
            time.sleep(100 * time.Millisecond)
            continue
        }

        engine_draw(self)
    }
}

@(private="file")
engine_draw :: proc(self: ^VulkanEngine) {

}

@(private="file")
_init_vulkan :: proc(self: ^VulkanEngine) -> (ok: bool) {
    defer free_all(context.temp_allocator)
    log.info("Initializing Vulkan instance...")

    //
    // Create Vulkan instance
    //
    {
        sdl_instance_extension_count := u32(0)
        sdl_instance_extensions := sdl.Vulkan_GetInstanceExtensions(&sdl_instance_extension_count)

        instance_config := vkbootstrap_init_instance_config()
        instance_config.min_api_version = vk.API_VERSION_1_3
        instance_config.required_extensions = sdl_instance_extensions[:sdl_instance_extension_count]

        self.instance, self.debug_messenger, ok = vkbootstrap_create_instance(instance_config)
        if !ok {
            log.error("Failed to create Vulkan instance")
            return false
        }

        log.info("Vulkan instance created successfully")
    }

    //
    // Create Vulkan surface
    //
    {
        if !sdl.Vulkan_CreateSurface(self.window, self.instance, nil, &self.surface) {
            log.error("Failed to create Vulkan surface: %s", sdl.GetError())
            return false
        }
        log.info("Vulkan surface created successfully")
    }

    //
    // Select physical device
    //
    bootstrap_physical_device: Physical_Device
    {
        physical_device_config := vkbootstrap_init_physical_device_config(self.instance, self.surface)
        physical_device_config.min_api_version = vk.API_VERSION_1_3
        vkbootstrap_set_physical_device_required_features_1_2(&physical_device_config, &vk.PhysicalDeviceVulkan12Features{
            bufferDeviceAddress = true,
            descriptorIndexing = true,
        })
        vkbootstrap_set_physical_device_required_features_1_3(&physical_device_config, &vk.PhysicalDeviceVulkan13Features{
            dynamicRendering = true,
            synchronization2 = true,
        })

        bootstrap_physical_device, ok = vkbootstrap_select_physical_device(physical_device_config)
        if !ok {
            log.error("Failed to select physical device")
            return false
        }

        self.physical_device = bootstrap_physical_device.handle
        vk.GetPhysicalDeviceProperties(self.physical_device, &self.physical_device_properties)
        vk.GetPhysicalDeviceFeatures(self.physical_device, &self.physical_device_features)
        vk.GetPhysicalDeviceMemoryProperties(self.physical_device, &self.physical_device_memory_properties)

        log.infof("Physical device selected successfully: %s", cstring(&self.physical_device_properties.deviceName[0]))

        self.graphics_queue_family_index = bootstrap_physical_device.graphics_queue_family_index
        self.present_queue_family_index = bootstrap_physical_device.present_queue_family_index
        self.compute_queue_family_index = bootstrap_physical_device.compute_queue_family_index
        self.transfer_queue_family_index = bootstrap_physical_device.transfer_queue_family_index
    }

    //
    // Create logical device
    //
    {
        device_config := vkbootstrap_init_device_config(bootstrap_physical_device)
        bootstrap_device: Device
        bootstrap_device, ok = vkbootstrap_create_device(device_config)
        if !ok {
            log.error("Failed to create logical device")
            return false
        }

        self.device = bootstrap_device.handle
        self.graphics_queue = bootstrap_device.graphics_queue
        self.present_queue = bootstrap_device.present_queue
        self.compute_queue = bootstrap_device.compute_queue
        self.transfer_queue = bootstrap_device.transfer_queue

        log.info("Logical device created successfully")
    }

    return true
}

@(private="file")
_init_swapchain :: proc(self: ^VulkanEngine) -> (ok: bool) {
    return _create_swapchain(self, self.window_extent.width, self.window_extent.height)
}

@(private="file")
_create_swapchain :: proc(self: ^VulkanEngine, width, height: u32) -> (ok: bool) {
    defer free_all(context.temp_allocator)
    log.info("Creating Vulkan swapchain...")

    if self.surface == 0 {
        log.error("Vulkan surface is not created")
        return false
    }

    swapchain_config := vkbootstrap_init_swapchain_config(
        self.physical_device,
        self.device,
        self.surface,
        self.graphics_queue_family_index, self.present_queue_family_index,
        width, height,
    )
    swapchain_config.desired_present_mode = .FIFO
    swapchain_config.desired_format = vk.SurfaceFormatKHR{ .B8G8R8A8_UNORM, .SRGB_NONLINEAR }

    bootstrap_swapchain: Swapchain
    bootstrap_swapchain, ok = vkbootstrap_create_swapchain(swapchain_config)
    if !ok {
        log.error("Failed to create Vulkan swapchain")
        return false
    }

    self.swapchain             = bootstrap_swapchain.handle
    self.swapchain_extent      = bootstrap_swapchain.extent
    self.swapchain_images      = bootstrap_swapchain.images
    self.swapchain_image_views = bootstrap_swapchain.image_views
    self.swapchain_extent      = bootstrap_swapchain.extent

    return true
}

@(private="file")
_destroy_swapchain :: proc(self: ^VulkanEngine) {
    for swapchain_image_view in self.swapchain_image_views {
        vk.DestroyImageView(self.device, swapchain_image_view, nil)
    }
    delete_dynamic_array(self.swapchain_image_views)
    delete_dynamic_array(self.swapchain_images)
    if self.swapchain != 0 {
        vk.DestroySwapchainKHR(self.device, self.swapchain, nil)
        self.swapchain = 0
    }
}

