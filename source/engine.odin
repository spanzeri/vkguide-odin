package vkguide

import "core:log"
import "core:time"
import "core:math"

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

    frames:                             [INFLIGHT_FRAME_OVERLAP]Frame_Data,
    frame_number:                       u64,
}

Engine_Init_Options :: struct {
    title:          string,
    window_size:    Vec2i,
}

Frame_Data :: struct {
    command_pool:               vk.CommandPool,
    main_command_buffer:        vk.CommandBuffer,
    swapchain_semaphore:        vk.Semaphore,
    render_finished_semaphore:  vk.Semaphore,
    render_fence:               vk.Fence,
}

INFLIGHT_FRAME_OVERLAP :: 2

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

    if !_init_commands(self) {
        log.error("Failed to initialize Vulkan command pools and buffers")
        return false
    }

    if !_init_sync_structures(self) {
        log.error("Failed to initialize Vulkan synchronization structures")
        return false
    }

    return true
}

engine_shutdown :: proc(self: ^VulkanEngine) {
    vk.DeviceWaitIdle(self.device)
    _destroy_swapchain(self)

    for i in 0 ..< INFLIGHT_FRAME_OVERLAP {
        if self.frames[i].render_fence != 0 {
            vk.WaitForFences(self.device, 1, &self.frames[i].render_fence, true, u64(1e9))
            vk.DestroyFence(self.device, self.frames[i].render_fence, nil)
            self.frames[i].render_fence = 0
        }
        if self.frames[i].render_finished_semaphore != 0 {
            vk.DestroySemaphore(self.device, self.frames[i].render_finished_semaphore, nil)
            self.frames[i].render_finished_semaphore = 0
        }
        if self.frames[i].swapchain_semaphore != 0 {
            vk.DestroySemaphore(self.device, self.frames[i].swapchain_semaphore, nil)
            self.frames[i].swapchain_semaphore = 0
        }

        if self.frames[i].main_command_buffer != nil {
            vk.FreeCommandBuffers(self.device, self.frames[i].command_pool, 1, &self.frames[i].main_command_buffer)
            self.frames[i].main_command_buffer = nil
        }
        if self.frames[i].command_pool != 0 {
            vk.DestroyCommandPool(self.device, self.frames[i].command_pool, nil)
            self.frames[i].command_pool = 0
        }
    }

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
        } else {
            engine_draw(self)
        }
    }
}

@(private="file")
engine_draw :: proc(self: ^VulkanEngine) -> (ok: bool) {
    frame := _get_current_frame(self)
    one_sec := u64(1e9)
    vk_check(vk.WaitForFences(self.device, 1, &frame.render_fence, true, one_sec)) or_return
    vk_check(vk.ResetFences(self.device, 1, &frame.render_fence)) or_return

    image_index: u32
    vk_check(vk.AcquireNextImageKHR(
        self.device,
        self.swapchain,
        one_sec,
        frame.swapchain_semaphore,
        0,
        &image_index,
    )) or_return

    // Reset command buffer
    cmd := frame.main_command_buffer
    vk_check(vk.ResetCommandBuffer(cmd, {})) or_return

    // Begin command buffer recording
    cmd_begin_info := init_command_buffer_begin_info({ .ONE_TIME_SUBMIT })
    vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info)) or_return

    // Transition the swapchain image to GENERAL layout
    vkutil_transition_image(cmd, self.swapchain_images[image_index], .UNDEFINED, .GENERAL)

    // Make a clear color for the image
    flash := math.abs(math.sin(f32(self.frame_number) / f32(120)))
    clear_color := vk.ClearColorValue{ float32 = [4]f32{0.0, 0.0, flash, 1.0} }

    clear_range := init_subresource_range({ .COLOR })

    // Clear the image
    vk.CmdClearColorImage(cmd, self.swapchain_images[image_index], .GENERAL, &clear_color, 1, &clear_range)

    // Transition the image into something that can be presented
    vkutil_transition_image(cmd, self.swapchain_images[image_index], .GENERAL, .PRESENT_SRC_KHR)

    vk_check(vk.EndCommandBuffer(cmd)) or_return

    // Prepare the submission to the queue.
    // We want to wait on the present semaphore, and signal the render finished semaphore.
    cmd_info    := init_command_buffer_submit_info(cmd)
    wait_info   := init_semaphore_submit_info({ .COLOR_ATTACHMENT_OUTPUT }, frame.swapchain_semaphore)
    signal_info := init_semaphore_submit_info({ .ALL_GRAPHICS }, frame.render_finished_semaphore)

    submit_info := init_submit_info(&cmd_info, &signal_info, &wait_info)

    // Submit the command buffer to the graphics queue
    vk_check(vk.QueueSubmit2(self.graphics_queue, 1, &submit_info, frame.render_fence)) or_return

    // Present the image
    present_info := vk.PresentInfoKHR{
        sType =              .PRESENT_INFO_KHR,
        pNext =              nil,
        pSwapchains =         &self.swapchain,
        swapchainCount =     1,
        pWaitSemaphores =    &frame.render_finished_semaphore,
        waitSemaphoreCount = 1,
        pImageIndices =      &image_index,
    }
    vk_check(vk.QueuePresentKHR(self.present_queue, &present_info)) or_return

    // Increment the frame number
    self.frame_number += 1

    return true
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

        log.infof(
            "Physical device selected successfully: %s",
            cstring(&self.physical_device_properties.deviceName[0]),
        )

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

@(private="file")
_init_commands :: proc(self: ^VulkanEngine) -> (ok: bool) {
    command_pool_create_info := init_command_pool_crate_info(
        self.graphics_queue_family_index,
        { .RESET_COMMAND_BUFFER },
    )

    for i in 0 ..< INFLIGHT_FRAME_OVERLAP {
        if !vk_check(vk.CreateCommandPool(
            self.device,
            &command_pool_create_info,
            nil,
            &self.frames[i].command_pool,
        )) {
            log.error("Failed to create command pool for frame %d", i)
            return false
        }

        command_buffer_allocate_info := init_command_buffer_allocate_info(
            self.frames[i].command_pool,
            1,
        )

        if !vk_check(vk.AllocateCommandBuffers(
            self.device,
            &command_buffer_allocate_info,
            &self.frames[i].main_command_buffer,
        )) {
            log.error("Failed to allocate command buffer for frame %d", i)
            return false
        }
    }

    log.info("Command pools and command buffers created successfully")
    return true
}

@(private="file")
_init_sync_structures :: proc(self: ^VulkanEngine) -> (ok: bool) {
    fence_create_info := init_fence_create_info({ .SIGNALED })
    semaphore_create_info := init_semaphore_create_info()

    for i in 0 ..< INFLIGHT_FRAME_OVERLAP {
        vk_check(vk.CreateFence(self.device, &fence_create_info, nil, &self.frames[i].render_fence)) or_return
        vk_check(
            vk.CreateSemaphore(self.device, &semaphore_create_info, nil, &self.frames[i].swapchain_semaphore),
        ) or_return
        vk_check(
            vk.CreateSemaphore(self.device, &semaphore_create_info, nil, &self.frames[i].render_finished_semaphore),
        ) or_return
    }

    return true
}

@(private="file")
_get_current_frame :: proc(self: ^VulkanEngine) -> (frame: ^Frame_Data) {
    frame_index := u32(self.frame_number % INFLIGHT_FRAME_OVERLAP)
    return &self.frames[frame_index]
}

