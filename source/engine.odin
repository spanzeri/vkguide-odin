package vkguide

import "base:runtime"
import "core:log"
import "core:math"
import "core:time"
import "core:os"

// @NOTE: I couldn't find a better way to silence the compiler warning about
// os not being used if FORCE_X11_VIDEO below is not defined.
_ :: os.set_env

import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import vma "lib:vma"

when ODIN_OS == .Linux {
    FORCE_X11_VIDEO_DRIVER :: #config(FORCE_X11_VIDEO, false)
}

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

    allocator:                          vma.Allocator,

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
    swapchain_present_semaphores:       [dynamic]vk.Semaphore,
    swapchain_extent:                   vk.Extent2D,

    draw_image:                         Allocated_Image,
    draw_image_extent:                  vk.Extent2D,

    global_descriptor_allocator:        vk.DescriptorPool,

    draw_image_descriptor_set:          vk.DescriptorSet,
    draw_image_descriptor_set_layout:   vk.DescriptorSetLayout,

    gradient_pipeline:                  vk.Pipeline,
    gradient_pipeline_layout:           vk.PipelineLayout,

    frames:                             [INFLIGHT_FRAME_OVERLAP]Frame_Data,
    frame_number:                       u64,

    deletion_queue:                     Deletion_Queue,
}

Engine_Init_Options :: struct {
    title:          string,
    window_size:    Vec2i,
}

Frame_Data :: struct {
    command_pool:               vk.CommandPool,
    main_command_buffer:        vk.CommandBuffer,
    swapchain_semaphore:        vk.Semaphore,
    render_fence:               vk.Fence,
    deletion_queue:             Deletion_Queue,
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

    when ODIN_OS == .Linux && FORCE_X11_VIDEO_DRIVER {
        os.set_env("SDL_VIDEODRIVER", "x11")
    }

    if !sdl.Init(sdl.INIT_VIDEO) {
        log.error("Failed to initialize SDL: %v", sdl.GetError())
        return false
    }

    self.window = sdl.CreateWindow("Vulkan Engine", opts.window_size.x, opts.window_size.y, sdl.WINDOW_VULKAN)
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

    if !_init_descriptors(self) {
        log.error("Failed to initialize Vulkan descriptors")
        return false
    }

    if !_init_pipelines(self) {
        log.error("Failed to initialize Vulkan pipelines")
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

        deletion_queue_destroy(&self.frames[i].deletion_queue)
    }

    deletion_queue_destroy(&self.deletion_queue)

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

    deletion_queue_flush(&frame.deletion_queue)

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

    // Prepare to draw to the render image
    self.draw_image_extent.width  = self.draw_image.extent.width
    self.draw_image_extent.height = self.draw_image.extent.height

    image_transition(cmd, self.draw_image.image, .UNDEFINED, .GENERAL)

    // Draw background ...
    if false {
        // ... Either with a clear
        // Make a clear color for the image
        flash := math.abs(math.sin(f32(self.frame_number) / f32(120)))
        clear_color := vk.ClearColorValue{ float32 = [4]f32{0.0, 0.0, flash, 1.0} }

        clear_range := init_subresource_range({ .COLOR })

        // Clear the image
        vk.CmdClearColorImage(cmd, self.draw_image.image, .GENERAL, &clear_color, 1, &clear_range)
    } else {
        // ... Or with a compute shader
        vk.CmdBindPipeline(cmd, .COMPUTE, self.gradient_pipeline)

        // Bind the descriptor set for the draw image
        vk.CmdBindDescriptorSets(cmd, .COMPUTE, self.gradient_pipeline_layout, 0, 1, &self.draw_image_descriptor_set, 0, nil)

        // Dispatch the compute shader to fill the image
        vk.CmdDispatch(
            cmd,
            u32(math.ceil_f32(f32(self.draw_image_extent.width)  / 16.0)),
            u32(math.ceil_f32(f32(self.draw_image_extent.height) / 16.0)),
            1,
        )
    }

    // Transition the image into something that can be presented
    image_transition(cmd, self.draw_image.image, .GENERAL, .TRANSFER_SRC_OPTIMAL)
    image_transition(cmd, self.swapchain_images[image_index], .UNDEFINED, .TRANSFER_DST_OPTIMAL)

    copy_image_to_image(
        cmd,
        self.draw_image.image,
        self.swapchain_images[image_index],
        self.draw_image_extent,
        self.swapchain_extent,
    )

    // Transition the swapchain image to a layout that can be presented
    image_transition(cmd, self.swapchain_images[image_index], .TRANSFER_DST_OPTIMAL, .PRESENT_SRC_KHR)

    vk_check(vk.EndCommandBuffer(cmd)) or_return

    // Prepare the submission to the queue.
    // We want to wait on the present semaphore, and signal the render finished semaphore.
    cmd_info    := init_command_buffer_submit_info(cmd)
    wait_info   := init_semaphore_submit_info({ .COLOR_ATTACHMENT_OUTPUT }, frame.swapchain_semaphore)
    signal_info := init_semaphore_submit_info({ .ALL_GRAPHICS }, self.swapchain_present_semaphores[image_index])

    submit_info := init_submit_info(&cmd_info, &signal_info, &wait_info)

    // Submit the command buffer to the graphics queue
    vk_check(vk.QueueSubmit2(self.graphics_queue, 1, &submit_info, frame.render_fence)) or_return

    // Present the image
    present_info := vk.PresentInfoKHR{
        sType =              .PRESENT_INFO_KHR,
        pNext =              nil,
        pSwapchains =         &self.swapchain,
        swapchainCount =     1,
        pWaitSemaphores =    &self.swapchain_present_semaphores[image_index],
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

    //
    // Init deletion queue
    //

    deletion_queue_init(&self.deletion_queue, self.device, context.allocator)

    //
    // Create VMA allocator
    //
    {
        vma_vulkan_functions := vma.create_vulkan_functions()
        vma_config := vma.Allocator_Create_Info{
            physical_device  = self.physical_device,
            device           = self.device,
            instance         = self.instance,
            flags            = { .BufferDeviceAddress },
            vulkan_functions = &vma_vulkan_functions,
        }

        if vma.create_allocator(vma_config, &self.allocator) != .SUCCESS {
            log.error("Failed to create VMA allocator")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.allocator)
    }

    return true
}

@(private="file")
_init_swapchain :: proc(self: ^VulkanEngine) -> (ok: bool) {
    if !_create_swapchain(self, self.window_extent.width, self.window_extent.height) {
        log.error("Failed to create Vulkan swapchain")
        return false
    }

    draw_image_extent := vk.Extent3D{
        width  = self.window_extent.width,
        height = self.window_extent.height,
        depth  = 1,
    }

    self.draw_image.format = .R16G16B16A16_SFLOAT
    self.draw_image.extent = draw_image_extent

    draw_image_usage_flags :vk.ImageUsageFlags= { .TRANSFER_SRC, .TRANSFER_DST, .STORAGE, .COLOR_ATTACHMENT }

    image_create_info := init_image_create_info(
        self.draw_image.format,
        draw_image_usage_flags,
        draw_image_extent,
    )

    alloc_info := vma.Allocation_Create_Info{
        usage          = .GPUOnly,
        required_flags = { .DEVICE_LOCAL },
    }

    vk_check(
        vma.create_image(
            self.allocator,
            image_create_info,
            alloc_info,
            &self.draw_image.image,
            &self.draw_image.allocation,
            nil,
        ),
    ) or_return
    defer if !ok {
        vma.destroy_image(self.allocator, self.draw_image.image, nil)
    }

    image_view_create_info := init_image_view_create_info(
        self.draw_image.format,
        self.draw_image.image,
        { .COLOR },
    )

    vk_check(vk.CreateImageView(self.device, &image_view_create_info, nil, &self.draw_image.view)) or_return

    deletion_queue_push(&self.deletion_queue, Image_With_Allocator{ self.draw_image, self.allocator })

    return true
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

    self.swapchain_present_semaphores = make_dynamic_array_len(
        [dynamic]vk.Semaphore,
        len(self.swapchain_images),
        context.allocator,
    )

    for i in 0 ..< len(self.swapchain_images) {
        semaphore_create_info := init_semaphore_create_info()
        vk_check(vk.CreateSemaphore(self.device, &semaphore_create_info, nil, &self.swapchain_present_semaphores[i])) or_return
    }

    return true
}

@(private="file")
_destroy_swapchain :: proc(self: ^VulkanEngine) {
    for swapchain_present_semaphore in self.swapchain_present_semaphores {
        vk.DestroySemaphore(self.device, swapchain_present_semaphore, nil)
    }
    delete_dynamic_array(self.swapchain_present_semaphores)
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
    }

    return true
}

@(private="file")
_init_descriptors :: proc(self: ^VulkanEngine) -> (ok: bool) {
    ratios := []Pool_Size_Ratio{
        { type = .STORAGE_IMAGE, ratio = 1.0 },
    }

    self.global_descriptor_allocator = descriptor_pool_init(self.device, 10, ratios)

    // Make the descriptor set layout for the compute draw
    {
        builder := descriptor_layout_builder_init()
        defer descriptor_layout_builder_destroy(&builder)

        descriptor_layout_builder_add_binding(&builder, 0, .STORAGE_IMAGE)

        self.draw_image_descriptor_set_layout = descriptor_layout_builder_build(
            &builder,
            self.device,
            { .COMPUTE },
        )
    }

    // Make sure we delete the descriptor set layout and pool at shutdown

    deletion_queue_push(&self.deletion_queue, self.global_descriptor_allocator)
    deletion_queue_push(&self.deletion_queue, self.draw_image_descriptor_set_layout)

    // Allocate the descriptor set for the draw image
    {
        self.draw_image_descriptor_set = descriptor_pool_allocate(
            self.global_descriptor_allocator,
            self.device,
            self.draw_image_descriptor_set_layout,
        )
        if self.draw_image_descriptor_set == 0 {
            log.error("Failed to allocate descriptor set for draw image")
            return false
        }

        image_info := vk.DescriptorImageInfo{
            imageLayout = .GENERAL,
            imageView = self.draw_image.view,
        }

        draw_image_write := vk.WriteDescriptorSet{
            sType = .WRITE_DESCRIPTOR_SET,
            dstBinding = 0,
            dstSet = self.draw_image_descriptor_set,
            descriptorCount = 1,
            descriptorType = .STORAGE_IMAGE,
            pImageInfo = &image_info,
        }

        vk.UpdateDescriptorSets(self.device, 1, &draw_image_write, 0, nil)
    }

    return true
}

@(private="file")
_init_pipelines :: proc(self: ^VulkanEngine) -> (ok: bool) {
    if !_init_background_pipelines(self) {
        log.error("Failed to initialize background compute pipelines")
        return false
    }

    return true
}

@(private="file")
_init_background_pipelines :: proc(self: ^VulkanEngine) -> (ok: bool) {
    // Create gradient compute pipeline layout
    {
        compute_pipeline_layout_create_info := vk.PipelineLayoutCreateInfo{
            sType          = .PIPELINE_LAYOUT_CREATE_INFO,
            pSetLayouts    = &self.draw_image_descriptor_set_layout,
            setLayoutCount = 1,
        }

        if !vk_check(vk.CreatePipelineLayout(
            self.device,
            &compute_pipeline_layout_create_info,
            nil,
            &self.gradient_pipeline_layout,
        )) {
            log.error("Failed to create gradient compute pipeline layout")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.gradient_pipeline_layout)
    }

    // Create gradient compute pipeline
    {
        compute_shader_mod : vk.ShaderModule
        compute_shader_mod, ok = load_shader_module(self.device, "bin/shaders/gradient.comp.spv")
        if !ok {
            log.error("Failed to load gradient compute shader module")
            return false
        }
        defer vk.DestroyShaderModule(self.device, compute_shader_mod, nil)

        stage_create_info := vk.PipelineShaderStageCreateInfo{
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage = { .COMPUTE },
            module = compute_shader_mod,
            pName = "main",
        }

        compute_pipeline_create_info := vk.ComputePipelineCreateInfo{
            sType = .COMPUTE_PIPELINE_CREATE_INFO,
            stage = stage_create_info,
            layout = self.gradient_pipeline_layout,
        }

        if !vk_check(vk.CreateComputePipelines(
            self.device,
            0, // cache
            1,
            &compute_pipeline_create_info,
            nil,
            &self.gradient_pipeline,
        )) {
            log.error("Failed to create gradient compute pipeline")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.gradient_pipeline)

        log.infof("Gradient compute pipeline created successfully")
    }

    return true
}

@(private="file")
_get_current_frame :: proc(self: ^VulkanEngine) -> (frame: ^Frame_Data) {
    frame_index := u32(self.frame_number % INFLIGHT_FRAME_OVERLAP)
    return &self.frames[frame_index]
}

//
// Deletion queue
//

Deletion_Queue :: struct {
    device:     vk.Device,
    resources:  [dynamic]Delete_Resource,
}

Image_With_Allocator :: struct {
    image:      Allocated_Image,
    allocator:  vma.Allocator,
}

Delete_Resource :: union {
    proc "c" (),

    vk.Pipeline,
    vk.PipelineLayout,

    vk.DescriptorSetLayout,
    vk.DescriptorPool,

    vk.ImageView,
    vk.Sampler,

    vk.CommandPool,

    vk.Fence,
    vk.Semaphore,

    vk.Buffer,
    vk.DeviceMemory,

    vma.Allocator,

    Image_With_Allocator,
}

deletion_queue_init :: proc(
    self: ^Deletion_Queue,
    device: vk.Device,
    allocator: runtime.Allocator = context.allocator,
) {
    self.device = device
    self.resources = make_dynamic_array_len_cap([dynamic]Delete_Resource, 0, 128, allocator)
}

deletion_queue_destroy :: proc(self: ^Deletion_Queue) {
    assert(self != nil)
    deletion_queue_flush(self)
    delete_dynamic_array(self.resources)
}

deletion_queue_push :: proc(self: ^Deletion_Queue, resource: Delete_Resource) {
    append(&self.resources, resource)
}

deletion_queue_flush :: proc(self: ^Deletion_Queue) {
    assert(self != nil)
    #reverse for &resource in self.resources {
        switch &res in resource {
        case proc "c" ():            { res()                                                 }
        case vk.Pipeline:            { vk.DestroyPipeline(self.device, res, nil)             }
        case vk.PipelineLayout:      { vk.DestroyPipelineLayout(self.device, res, nil)       }
        case vk.DescriptorSetLayout: { vk.DestroyDescriptorSetLayout(self.device, res, nil)  }
        case vk.DescriptorPool:      { vk.DestroyDescriptorPool(self.device, res, nil)       }
        case vk.ImageView:           { vk.DestroyImageView(self.device, res, nil)            }
        case vk.Sampler:             { vk.DestroySampler(self.device, res, nil)              }
        case vk.CommandPool:         { vk.DestroyCommandPool(self.device, res, nil)          }
        case vk.Fence:               { vk.DestroyFence(self.device, res, nil)                }
        case vk.Semaphore:           { vk.DestroySemaphore(self.device, res, nil)            }
        case vk.Buffer:              { vk.DestroyBuffer(self.device, res, nil)               }
        case vk.DeviceMemory:        { vk.FreeMemory(self.device, res, nil)                  }
        case vma.Allocator:          { vma.destroy_allocator(res)                            }
        case Image_With_Allocator:   { image_destroy(&res.image, self.device, res.allocator) }
        case: {
            assert(false, "Unknown resource type in deletion queue")
        }
        }
    }
}
