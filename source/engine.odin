package vkguide

import intr "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:math"
import "core:mem"
import la "core:math/linalg"
import "core:os"
import "core:time"

// @NOTE: I couldn't find a better way to silence the compiler warning about
// os not being used if FORCE_X11_VIDEO below is not defined.
_ :: os.set_env

import vma "lib:vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

// Forcing X11 on linux fixes the problem with renderdoc unable to capture the
// window on wayland.
when ODIN_OS == .Linux {
    FORCE_X11_VIDEO_DRIVER :: #config(FORCE_X11_VIDEO, true)
}

Engine :: struct {
    window:                             ^sdl.Window,
    minimized:                          bool,
    resize_required:                    bool,
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
    depth_image:                        Allocated_Image,
    draw_image_extent:                  vk.Extent2D,
    global_descriptor_allocator:        vk.DescriptorPool,
    draw_image_descriptor_set:          vk.DescriptorSet,
    draw_image_descriptor_set_layout:   vk.DescriptorSetLayout,
    gpu_scene_data:                     Gpu_Scene_Data,
    gpu_scene_data_descriptor_set_layout: vk.DescriptorSetLayout,
    single_image_descriptor_layout:     vk.DescriptorSetLayout,

    gradient_pipeline:                  vk.Pipeline,
    gradient_pipeline_layout:           vk.PipelineLayout,
    triangle_pipeline:                  vk.Pipeline,
    triangle_pipeline_layout:           vk.PipelineLayout,
    mesh_pipeline:                      vk.Pipeline,
    mesh_pipeline_layout:               vk.PipelineLayout,

    ui_pipeline:                        vk.Pipeline,
    ui_pipeline_layout:                 vk.PipelineLayout,
    ui_vertex_buffer:                   Allocated_Buffer,
    ui_index_buffer:                    Allocated_Buffer,
    ui_vertex_buffer_address:           vk.DeviceAddress,

    rectangle:                          Gpu_Mesh_Buffers,
    meshes:                             [dynamic]Mesh_Asset,

    // Default textures
    white_image:                        Allocated_Image,
    black_image:                        Allocated_Image,
    grey_image:                         Allocated_Image,
    error_checkerboard_image:           Allocated_Image,

    default_sampler_linear:             vk.Sampler,
    default_sampler_nearest:            vk.Sampler,

    // Immediate submit structures
    immediate_fence:                    vk.Fence,
    immediate_command_pool:             vk.CommandPool,
    immediate_command_buffer:           vk.CommandBuffer,
    frames:                             [INFLIGHT_FRAME_OVERLAP]Frame_Data,
    frame_number:                       u64,
    deletion_queue:                     Deletion_Queue,
}

Engine_Init_Options :: struct {
    title:       string,
    window_size: Vec2i,
}

Frame_Data :: struct {
    command_pool:        vk.CommandPool,
    main_command_buffer: vk.CommandBuffer,
    swapchain_semaphore: vk.Semaphore,
    render_fence:        vk.Fence,
    deletion_queue:      Deletion_Queue,
    frame_descriptors:   Descriptor_Growable_Allocator,
}

Allocated_Buffer :: struct {
    buffer:     vk.Buffer,
    allocation: vma.Allocation,
    info:       vma.Allocation_Info,
}

Vertex :: struct {
    position: Vec3,
    uv_x:     f32,
    normal:   Vec3,
    uv_y:     f32,
    color:    Vec4,
}

Ui_Vertex :: struct {
    position : Vec2,
    uvs : Vec2,
    color : Vec3,
    flags : u32,
}

Gpu_Mesh_Buffers :: struct {
    index_buffer:          Allocated_Buffer,
    vertex_buffer:         Allocated_Buffer,
    vertex_buffer_address: vk.DeviceAddress,
}

Gpu_Draw_Push_Constants :: struct {
    world_matrix:  Mat4,
    vertex_buffer: vk.DeviceAddress,
}

Gpu_Scene_Data :: struct {
    view:               Mat4,
    projection:         Mat4,
    viewproj:           Mat4,
    ambient_color:      Vec4,
    sunlight_direction: Vec4, // w for intensity
    sunlight_color:     Vec4,
}

INFLIGHT_FRAME_OVERLAP :: 2

@(require_results)
engine_init :: proc(
    self: ^Engine,
    opts: Engine_Init_Options = {title = "Vulkan Engine", window_size = Vec2i{1024, 768}},
) -> (
    ok: bool,
) {
    assert(self != nil, "VulkanEngine cannot be nil")
    assert(self.window == nil, "VulkanEngine window must be nil on initialization")

    when ODIN_OS == .Linux && FORCE_X11_VIDEO_DRIVER {
        os.set_env("SDL_VIDEODRIVER", "x11")
    }

    if !sdl.Init(sdl.INIT_VIDEO) {
        log.error("Failed to initialize SDL: %v", sdl.GetError())
        return false
    }

    window_flags := sdl.WindowFlags{.RESIZABLE, .HIGH_PIXEL_DENSITY, .VULKAN}
    self.window = sdl.CreateWindow(
        "Vulkan Engine",
        opts.window_size.x,
        opts.window_size.y,
        window_flags,
    )
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

    if !_init_default_data(self) {
        log.error("Failed to initialize default data")
        return false
    }

    if !_load_meshes(self) {
        log.error("Failed to load meshes")
        return false
    }

    return true
}

engine_shutdown :: proc(self: ^Engine) {
    vk.DeviceWaitIdle(self.device)

    delete_dynamic_array(self.meshes)

    _destroy_swapchain(self)

    for &frame in self.frames {
        if frame.render_fence != 0 {
            vk.WaitForFences(self.device, 1, &frame.render_fence, true, u64(1e9))
            vk.DestroyFence(self.device, frame.render_fence, nil)
            frame.render_fence = 0
        }
        if frame.swapchain_semaphore != 0 {
            vk.DestroySemaphore(self.device, frame.swapchain_semaphore, nil)
            frame.swapchain_semaphore = 0
        }

        if frame.main_command_buffer != nil {
            vk.FreeCommandBuffers(self.device, frame.command_pool, 1, &frame.main_command_buffer)
            frame.main_command_buffer = nil
        }
        if frame.command_pool != 0 {
            vk.DestroyCommandPool(self.device, frame.command_pool, nil)
            frame.command_pool = 0
        }

        deletion_queue_destroy(&frame.deletion_queue, self)
        descriptor_growable_allocator_destroy(&frame.frame_descriptors)
    }

    deletion_queue_destroy(&self.deletion_queue, self)

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

engine_run :: proc(self: ^Engine, ui: Ui_Context) {
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

            ui_update_input(ui, &event)
        }

        if self.resize_required {
            if !_resize_swapchain(self) {
                log.error("Failed to resize swapchain")
                return
            }
        }

        if self.minimized {
            time.sleep(100 * time.Millisecond)
            continue
        }

        {
            ui_begin(ui)
            ui_demo(ui)
            ui_end(ui)
        }

        engine_draw(self, ui)
    }
}

create_buffer :: proc(
    self: ^Engine,
    alloc_size: u64,
    usage: vk.BufferUsageFlags,
    memory_usage: vma.Memory_Usage,
) -> (
    allocated_buffer: Allocated_Buffer,
    ok: bool,
) {
    buffer_info := vk.BufferCreateInfo {
        sType       = .BUFFER_CREATE_INFO,
        size        = vk.DeviceSize(alloc_size),
        usage       = usage,
        sharingMode = .EXCLUSIVE,
    }

    alloc_info := vma.Allocation_Create_Info {
        usage = memory_usage,
        flags = {.MAPPED},
    }

    vk_check(
        vma.create_buffer(
            self.allocator,
            buffer_info,
            alloc_info,
            &allocated_buffer.buffer,
            &allocated_buffer.allocation,
            &allocated_buffer.info,
        ),
    ) or_return

    return allocated_buffer, true
}

destroy_buffer :: proc(allocator: vma.Allocator, allocated_buffer: ^Allocated_Buffer) {
    if allocated_buffer.buffer != 0 {
        vma.destroy_buffer(allocator, allocated_buffer.buffer, allocated_buffer.allocation)
        allocated_buffer.buffer = 0
        allocated_buffer.allocation = nil
    }
}

engine_create_image :: proc(
    self: ^Engine,
    size: vk.Extent3D,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    mipmapped := false,
) -> (image: Allocated_Image, ok: bool) {
    image.format = format
    image.extent = size

    image_info := init_image_create_info(format, usage, size)
    if mipmapped {
        image_info.mipLevels = _compute_mip_levels(image.extent)
    }

    alloc_info := vma.Allocation_Create_Info{
        usage = .GPU_ONLY,
        required_flags = { .DEVICE_LOCAL },
    }
    vk_check(
        vma.create_image(
            self.allocator,
            image_info,
            alloc_info,
            &image.image,
            &image.allocation,
            nil,
        ),
    ) or_return

    aspect_flags := vk.ImageAspectFlags{ .COLOR }
    is_depth, is_stencil := _is_depth_stencil_format(image.format)
    if is_depth || is_stencil   { aspect_flags = {} }
    if is_depth                 { aspect_flags |= { .DEPTH } }
    if is_stencil               { aspect_flags |= { .STENCIL } }

    view_info := init_image_view_create_info(image.format, image.image, aspect_flags)
    view_info.subresourceRange.levelCount = image_info.mipLevels
    vk_check(vk.CreateImageView(self.device, &view_info, nil, &image.view)) or_return

    return image, true
}

engine_create_image_with_data :: proc(
    self: ^Engine,
    data: []u8,
    size: vk.Extent3D,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
    mipmapped := false,
) -> (image: Allocated_Image, ok: bool) {
    data_size := u64(len(data))
    upload_buffer, buf_ok := create_buffer(self, data_size, { .TRANSFER_SRC }, .CPU_TO_GPU)
    if !buf_ok {
        log.error("Failed to allocate buffer for image upload")
        return
    }
    defer destroy_buffer(self.allocator, &upload_buffer)

    intr.mem_copy(upload_buffer.info.mapped_data, raw_data(data), data_size)

    image = engine_create_image(self, size, format, usage | { .TRANSFER_DST }, mipmapped) or_return

    Upload_Data :: struct {
        image:  Allocated_Image,
        buffer: Allocated_Buffer,
    }

    _immediate_submit(
        self,
        &Upload_Data{ image, upload_buffer },
        proc(self: ^Engine, cmd: vk.CommandBuffer, data: ^Upload_Data) {
            image_transition(cmd, data.image.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)

            copy_region := vk.BufferImageCopy{
                bufferOffset       = 0,
                bufferRowLength    = 0,
                bufferImageHeight  = 0,
                imageSubresource   = {
                    aspectMask     = { .COLOR },
                    mipLevel       = 0,
                    baseArrayLayer = 0,
                    layerCount     = 1,
                },
                imageExtent        = data.image.extent,
            }

            vk.CmdCopyBufferToImage(cmd, data.buffer.buffer, data.image.image, .TRANSFER_DST_OPTIMAL, 1, &copy_region)

            image_transition(cmd, data.image.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)
        },
    )

    return image, true
}

engine_destroy_image :: proc(self: ^Engine, image: Allocated_Image) {
    if image.view != 0 {
        vk.DestroyImageView(self.device, image.view, nil)
    }
    vma.destroy_image(self.allocator, image.image, image.allocation)
}

@(private="file")
_compute_mip_levels :: proc(size: vk.Extent3D) -> u32 {
    level := u32(0)
    ext := size
    for ext.width > 1 || ext.height > 1 || ext.depth > 1 {
        ext.width  = max(1, ext.width >> 1)
        ext.height = max(1, ext.height >> 1)
        ext.depth  = max(1, ext.depth >> 1)
        level += 1
    }
    return level + 1
}

@(private="file")
_is_depth_stencil_format :: proc(format: vk.Format) -> (depth: bool, stencil: bool) {
    #partial switch format {
    case .D32_SFLOAT:
        depth = true
    case .S8_UINT:
        stencil = true
    case .D16_UNORM_S8_UINT, .D24_UNORM_S8_UINT, .D32_SFLOAT_S8_UINT:
        depth = true
        stencil = true
    }
    return
}

@(private = "file")
engine_draw :: proc(self: ^Engine, ui: Ui_Context) -> (ok: bool) {
    frame := engine_get_current_frame(self)
    one_sec := u64(1e9)
    vk_check(vk.WaitForFences(self.device, 1, &frame.render_fence, true, one_sec)) or_return

    // Cleanup queue and descriptors for this frame
    deletion_queue_flush(&frame.deletion_queue, self)
    descriptor_growable_allocator_clear_pools(&frame.frame_descriptors)

    vk_check(vk.ResetFences(self.device, 1, &frame.render_fence)) or_return

    image_index: u32
    result := vk.AcquireNextImageKHR(
        self.device,
        self.swapchain,
        one_sec,
        frame.swapchain_semaphore,
        0,
        &image_index,
    )
    if result == .ERROR_OUT_OF_DATE_KHR {
        self.resize_required = true
        return true
    }
    if result != .SUCCESS {
        log.error("Failed to acquire next image: %v", result)
        return false
    }

    // Reset command buffer
    cmd := frame.main_command_buffer
    vk_check(vk.ResetCommandBuffer(cmd, {})) or_return

    // Begin command buffer recording
    cmd_begin_info := init_command_buffer_begin_info({.ONE_TIME_SUBMIT})
    vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info)) or_return

    // Prepare to draw to the render image
    self.draw_image_extent.width = self.draw_image.extent.width
    self.draw_image_extent.height = self.draw_image.extent.height

    // Transition into GENERAL layout for drawing with compute
    image_transition(cmd, self.draw_image.image, .UNDEFINED, .GENERAL)
    _draw_background(self, cmd)

    // Transition into color attachment optimal for normal rendering
    image_transition(cmd, self.draw_image.image, .GENERAL, .COLOR_ATTACHMENT_OPTIMAL)
    image_transition(cmd, self.depth_image.image, .UNDEFINED, .DEPTH_STENCIL_ATTACHMENT_OPTIMAL)

    // Rendering
    {
        // Dynamic rendering setup
        color_attachment := init_rendering_attachment_info(self.draw_image.view, nil)
        depth_attachment := init_depth_attachment_info(self.depth_image.view)
        render_info := init_rendering_info(
            self.draw_image_extent,
            &color_attachment,
            &depth_attachment,
        )

        vk.CmdBeginRendering(cmd, &render_info)
        defer vk.CmdEndRendering(cmd)

        _draw_geometry(self, cmd)

        // Draw UI
        {
            ui_draw_ctx := ui_render_context_init(self, cmd)
            ui_render_context_render(ui, &ui_draw_ctx)
        }
    }

    // Transition the image into something that can be presented
    image_transition(cmd, self.draw_image.image, .COLOR_ATTACHMENT_OPTIMAL, .TRANSFER_SRC_OPTIMAL)
    image_transition(cmd, self.swapchain_images[image_index], .UNDEFINED, .TRANSFER_DST_OPTIMAL)

    copy_image_to_image(
        cmd,
        self.draw_image.image,
        self.swapchain_images[image_index],
        self.draw_image_extent,
        self.swapchain_extent,
    )

    // Transition the swapchain image to a layout that can be presented
    image_transition(
        cmd,
        self.swapchain_images[image_index],
        .TRANSFER_DST_OPTIMAL,
        .PRESENT_SRC_KHR,
    )

    vk_check(vk.EndCommandBuffer(cmd)) or_return

    // Prepare the submission to the queue.
    // We want to wait on the present semaphore, and signal the render finished semaphore.
    cmd_info := init_command_buffer_submit_info(cmd)
    wait_info := init_semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT}, frame.swapchain_semaphore)
    signal_info := init_semaphore_submit_info(
        {.ALL_GRAPHICS},
        self.swapchain_present_semaphores[image_index],
    )

    submit_info := init_submit_info(&cmd_info, &signal_info, &wait_info)

    // Submit the command buffer to the graphics queue
    vk_check(vk.QueueSubmit2(self.graphics_queue, 1, &submit_info, frame.render_fence)) or_return

    // Present the image
    present_info := vk.PresentInfoKHR {
        sType              = .PRESENT_INFO_KHR,
        pNext              = nil,
        pSwapchains        = &self.swapchain,
        swapchainCount     = 1,
        pWaitSemaphores    = &self.swapchain_present_semaphores[image_index],
        waitSemaphoreCount = 1,
        pImageIndices      = &image_index,
    }
    result = vk.QueuePresentKHR(self.present_queue, &present_info)
    if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
        self.resize_required = true
    } else if result != .SUCCESS {
        log.error("Failed to present image: %v", result)
        return false
    }

    // Increment the frame number
    self.frame_number += 1

    return true
}

@(private = "file")
_draw_background :: proc(self: ^Engine, cmd: vk.CommandBuffer) {
    // Draw background ...
    if false {
        // ... Either with a clear
        // Make a clear color for the image
        flash := math.abs(math.sin(f32(self.frame_number) / f32(120)))
        clear_color := vk.ClearColorValue {
            float32 = [4]f32{0.0, 0.0, flash, 1.0},
        }

        clear_range := init_subresource_range({.COLOR})

        // Clear the image
        vk.CmdClearColorImage(cmd, self.draw_image.image, .GENERAL, &clear_color, 1, &clear_range)
    } else {
        // ... Or with a compute shader
        vk.CmdBindPipeline(cmd, .COMPUTE, self.gradient_pipeline)

        // Bind the descriptor set for the draw image
        vk.CmdBindDescriptorSets(
            cmd,
            .COMPUTE,
            self.gradient_pipeline_layout,
            0,
            1,
            &self.draw_image_descriptor_set,
            0,
            nil,
        )

        // Push constants to the compute shader
        pc := Compute_Push_Constants {
            data1 = Vec4{1.0, 0.0, 0.0, 1.0},
            data2 = Vec4{0.0, 0.0, 1.0, 1.0},
        }
        vk.CmdPushConstants(
            cmd,
            self.gradient_pipeline_layout,
            {.COMPUTE},
            0,
            size_of(Compute_Push_Constants),
            &pc,
        )

        // Dispatch the compute shader to fill the image
        vk.CmdDispatch(
            cmd,
            u32(math.ceil_f32(f32(self.draw_image_extent.width) / 16.0)),
            u32(math.ceil_f32(f32(self.draw_image_extent.height) / 16.0)),
            1,
        )
    }
}

@(private = "file")
_draw_geometry :: proc(self: ^Engine, cmd: vk.CommandBuffer) {
    // GPU scene data (buffer is allocated per-frame, as per the tutorial, but
    // it would be better to be cached)
    frame := engine_get_current_frame(self)

    gpu_scene_data_buffer, ok := create_buffer(
        self,
        size_of(Gpu_Scene_Data),
        {.UNIFORM_BUFFER},
        .CPU_TO_GPU,
    )
    assert(ok)
    deletion_queue_push(&frame.deletion_queue, gpu_scene_data_buffer)
    gpu_scene_data := cast(^Gpu_Scene_Data)(gpu_scene_data_buffer.info.mapped_data)
    gpu_scene_data^ = self.gpu_scene_data

    global_descriptor_set := descriptor_growable_allocator_allocate(
        &frame.frame_descriptors,
        self.gpu_scene_data_descriptor_set_layout,
    )

    writer := Descriptor_Writer{}
    descriptor_writer_write_buffer(
        &writer,
        0,
        gpu_scene_data_buffer.buffer,
        size_of(Gpu_Scene_Data),
        0,
        .UNIFORM_BUFFER,
    )
    descriptor_writer_update_set(&writer, self.device, global_descriptor_set)

    // Set up viewport and scissor
    viewport := vk.Viewport {
        x        = 0.0,
        y        = f32(self.draw_image_extent.height),
        width    = f32(self.draw_image_extent.width),
        height   = -f32(self.draw_image_extent.height),
        minDepth = 0.0,
        maxDepth = 1.0,
    }
    vk.CmdSetViewport(cmd, 0, 1, &viewport)

    scissor := vk.Rect2D {
        offset = {0, 0},
        extent = self.draw_image_extent,
    }
    vk.CmdSetScissor(cmd, 0, 1, &scissor)

    // Draw triangle (hard-coded)
    vk.CmdBindPipeline(cmd, .GRAPHICS, self.triangle_pipeline)
    vk.CmdDraw(cmd, 3, 1, 0, 0)

    // Draw rectangle (mesh buffers)
    vk.CmdBindPipeline(cmd, .GRAPHICS, self.mesh_pipeline)

    // Allocate image descriptor for mesh pipeline
    image_set := descriptor_growable_allocator_allocate(
        &frame.frame_descriptors,
        self.single_image_descriptor_layout,
    )
    {
        writer = Descriptor_Writer{}
        descriptor_writer_write_image(
            &writer,
            0,
            self.error_checkerboard_image.view,
            self.default_sampler_nearest,
        )
        descriptor_writer_update_set(&writer, self.device, image_set)
    }
    vk.CmdBindDescriptorSets(cmd, .GRAPHICS, self.mesh_pipeline_layout, 0, 1, &image_set, 0, nil)

    vk.CmdPushConstants(
        cmd,
        self.mesh_pipeline_layout,
        {.VERTEX},
        0,
        size_of(Gpu_Draw_Push_Constants),
        &Gpu_Draw_Push_Constants {
            world_matrix = la.identity_matrix(Mat4),
            vertex_buffer = self.rectangle.vertex_buffer_address,
        },
    )
    vk.CmdBindIndexBuffer(cmd, self.rectangle.index_buffer.buffer, 0, .UINT32)
    vk.CmdDrawIndexed(cmd, 6, 1, 0, 0, 0)

    view := la.matrix4_translate_f32({0, 0, -5})
    proj := matrix4_infinite_perspective_reverse_z_f32(
        math.to_radians_f32(70.0),
        f32(self.draw_image_extent.width) / f32(self.draw_image_extent.height),
        0.1,
    )

    // Draw meshes
    for mesh, mi in self.meshes {
        if mi != 2 { continue }
        vk.CmdPushConstants(
            cmd,
            self.mesh_pipeline_layout,
            {.VERTEX},
            0,
            size_of(Gpu_Draw_Push_Constants),
            &Gpu_Draw_Push_Constants {
                world_matrix = proj * view,
                vertex_buffer = mesh.mesh_buffers.vertex_buffer_address,
            },
        )

        vk.CmdBindIndexBuffer(cmd, mesh.mesh_buffers.index_buffer.buffer, 0, .UINT32)

        for surface in mesh.surfaces {
            vk.CmdDrawIndexed(cmd, surface.count, 1, surface.start_index, 0, 0)
        }
    }
}

@(private = "file")
_immediate_submit :: proc(
    self: ^Engine,
    data: ^$Data_Type,
    func: proc(self: ^Engine, cmd: vk.CommandBuffer, data: ^Data_Type),
) {
    if !vk_check(vk.ResetFences(self.device, 1, &self.immediate_fence)) {
        panic("Failed to reset immediate fence")
    }
    if !vk_check(vk.ResetCommandBuffer(self.immediate_command_buffer, {})) {
        panic("Failed to reset immediate command buffer")
    }

    cmd := self.immediate_command_buffer
    cmd_begin_info := init_command_buffer_begin_info({.ONE_TIME_SUBMIT})

    if !vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info)) {
        panic("Failed to begin immediate command buffer")
    }

    func(self, cmd, data)

    cmd_submit_info := init_command_buffer_submit_info(cmd)
    submit_info := init_submit_info(&cmd_submit_info, nil, nil)

    if !vk_check(vk.EndCommandBuffer(cmd)) {
        panic("Failed to end immediate command buffer")
    }
    if !vk_check(vk.QueueSubmit2(self.graphics_queue, 1, &submit_info, self.immediate_fence)) {
        panic("Failed to submit immediate command buffer")
    }
    if !vk_check(vk.WaitForFences(self.device, 1, &self.immediate_fence, true, u64(1e9))) {
        panic("Failed to wait for immediate fence")
    }
}

@(private = "file")
_init_vulkan :: proc(self: ^Engine) -> (ok: bool) {
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
        instance_config.required_extensions =
        sdl_instance_extensions[:sdl_instance_extension_count]

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
        physical_device_config := vkbootstrap_init_physical_device_config(
            self.instance,
            self.surface,
        )
        physical_device_config.min_api_version = vk.API_VERSION_1_3
        vkbootstrap_set_physical_device_required_features_1_2(
            &physical_device_config,
            &vk.PhysicalDeviceVulkan12Features {
                bufferDeviceAddress = true,
                descriptorIndexing = true,
            },
        )
        vkbootstrap_set_physical_device_required_features_1_3(
            &physical_device_config,
            &vk.PhysicalDeviceVulkan13Features{dynamicRendering = true, synchronization2 = true},
        )

        bootstrap_physical_device, ok = vkbootstrap_select_physical_device(physical_device_config)
        if !ok {
            log.error("Failed to select physical device")
            return false
        }

        self.physical_device = bootstrap_physical_device.handle
        vk.GetPhysicalDeviceProperties(self.physical_device, &self.physical_device_properties)
        vk.GetPhysicalDeviceFeatures(self.physical_device, &self.physical_device_features)
        vk.GetPhysicalDeviceMemoryProperties(
            self.physical_device,
            &self.physical_device_memory_properties,
        )

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
        vma_config := vma.Allocator_Create_Info {
            physical_device  = self.physical_device,
            device           = self.device,
            instance         = self.instance,
            flags            = {.BufferDeviceAddress},
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

@(private = "file")
_init_swapchain :: proc(self: ^Engine) -> (ok: bool) {
    if !_create_swapchain(self, self.window_extent.width, self.window_extent.height) {
        log.error("Failed to create Vulkan swapchain")
        return false
    }

    draw_image_extent := vk.Extent3D {
        width  = self.window_extent.width,
        height = self.window_extent.height,
        depth  = 1,
    }

    self.draw_image.format = .R16G16B16A16_SFLOAT
    self.draw_image.extent = draw_image_extent

    draw_image_usage_flags: vk.ImageUsageFlags = {
        .TRANSFER_SRC,
        .TRANSFER_DST,
        .STORAGE,
        .COLOR_ATTACHMENT,
    }

    image_create_info := init_image_create_info(
        self.draw_image.format,
        draw_image_usage_flags,
        draw_image_extent,
    )
    alloc_info := vma.Allocation_Create_Info {
        usage          = .GPU_ONLY,
        required_flags = {.DEVICE_LOCAL},
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
        {.COLOR},
    )
    vk_check(
        vk.CreateImageView(self.device, &image_view_create_info, nil, &self.draw_image.view),
    ) or_return

    deletion_queue_push(&self.deletion_queue, self.draw_image)

    self.depth_image.format = .D32_SFLOAT
    self.depth_image.extent = draw_image_extent

    depth_image_create_info := init_image_create_info(
        self.depth_image.format,
        {.DEPTH_STENCIL_ATTACHMENT},
        self.depth_image.extent,
    )
    depth_alloc_info := vma.Allocation_Create_Info {
        usage          = .GPU_ONLY,
        required_flags = {.DEVICE_LOCAL},
    }
    vk_check(
        vma.create_image(
            self.allocator,
            depth_image_create_info,
            depth_alloc_info,
            &self.depth_image.image,
            &self.depth_image.allocation,
            nil,
        ),
    ) or_return

    depth_image_view_create_info := init_image_view_create_info(
        self.depth_image.format,
        self.depth_image.image,
        {.DEPTH},
    )
    vk_check(
        vk.CreateImageView(
            self.device,
            &depth_image_view_create_info,
            nil,
            &self.depth_image.view,
        ),
    ) or_return

    deletion_queue_push(&self.deletion_queue, self.depth_image)

    return true
}

@(private = "file")
_create_swapchain :: proc(self: ^Engine, width, height: u32) -> (ok: bool) {
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
        self.graphics_queue_family_index,
        self.present_queue_family_index,
        width,
        height,
    )
    swapchain_config.desired_present_mode = .FIFO
    swapchain_config.desired_format = vk.SurfaceFormatKHR{.B8G8R8A8_UNORM, .SRGB_NONLINEAR}

    bootstrap_swapchain: Swapchain
    bootstrap_swapchain, ok = vkbootstrap_create_swapchain(swapchain_config)
    if !ok {
        log.error("Failed to create Vulkan swapchain")
        return false
    }

    self.swapchain = bootstrap_swapchain.handle
    self.swapchain_extent = bootstrap_swapchain.extent
    self.swapchain_images = bootstrap_swapchain.images
    self.swapchain_image_views = bootstrap_swapchain.image_views
    self.swapchain_extent = bootstrap_swapchain.extent

    self.swapchain_present_semaphores = make_dynamic_array_len(
        [dynamic]vk.Semaphore,
        len(self.swapchain_images),
        context.allocator,
    )

    for i in 0 ..< len(self.swapchain_images) {
        semaphore_create_info := init_semaphore_create_info()
        vk_check(
            vk.CreateSemaphore(
                self.device,
                &semaphore_create_info,
                nil,
                &self.swapchain_present_semaphores[i],
            ),
        ) or_return
    }

    return true
}

@(private = "file")
_resize_swapchain :: proc(self: ^Engine) -> (ok: bool) {
    vk.DeviceWaitIdle(self.device)
    _destroy_swapchain(self)
    w, h: i32
    sdl.GetWindowSizeInPixels(self.window, &w, &h)
    self.window_extent.width = u32(w)
    self.window_extent.height = u32(h)
    self.resize_required = false

    // image_destroy(&self.depth_image, self.device, self.allocator)
    // image_destroy(&self.draw_image, self.device, self.allocator)

    _create_swapchain(self, self.window_extent.width, self.window_extent.height) or_return

    return true
}

@(private = "file")
_destroy_swapchain :: proc(self: ^Engine) {
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

@(private = "file")
_init_commands :: proc(self: ^Engine) -> (ok: bool) {
    command_pool_create_info := init_command_pool_crate_info(
        self.graphics_queue_family_index,
        {.RESET_COMMAND_BUFFER},
    )

    for i in 0 ..< INFLIGHT_FRAME_OVERLAP {
        if !vk_check(
            vk.CreateCommandPool(
                self.device,
                &command_pool_create_info,
                nil,
                &self.frames[i].command_pool,
            ),
        ) {
            log.error("Failed to create command pool for frame %d", i)
            return false
        }

        command_buffer_allocate_info := init_command_buffer_allocate_info(
            self.frames[i].command_pool,
            1,
        )

        if !vk_check(
            vk.AllocateCommandBuffers(
                self.device,
                &command_buffer_allocate_info,
                &self.frames[i].main_command_buffer,
            ),
        ) {
            log.error("Failed to allocate command buffer for frame %d", i)
            return false
        }
    }

    // Create the immediate command pool and buffer
    {
        if !vk_check(
            vk.CreateCommandPool(
                self.device,
                &command_pool_create_info,
                nil,
                &self.immediate_command_pool,
            ),
        ) {
            log.error("Failed to create immediate command pool")
            return false
        }

        command_buffer_allocate_info := init_command_buffer_allocate_info(
            self.immediate_command_pool,
            1,
        )

        if !vk_check(
            vk.AllocateCommandBuffers(
                self.device,
                &command_buffer_allocate_info,
                &self.immediate_command_buffer,
            ),
        ) {
            log.error("Failed to allocate immediate command buffer")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.immediate_command_pool)
    }

    log.info("Command pools and command buffers created successfully")
    return true
}

@(private = "file")
_init_sync_structures :: proc(self: ^Engine) -> (ok: bool) {
    fence_create_info := init_fence_create_info({.SIGNALED})
    semaphore_create_info := init_semaphore_create_info()

    for i in 0 ..< INFLIGHT_FRAME_OVERLAP {
        vk_check(
            vk.CreateFence(self.device, &fence_create_info, nil, &self.frames[i].render_fence),
        ) or_return
        vk_check(
            vk.CreateSemaphore(
                self.device,
                &semaphore_create_info,
                nil,
                &self.frames[i].swapchain_semaphore,
            ),
        ) or_return
    }

    vk_check(vk.CreateFence(self.device, &fence_create_info, nil, &self.immediate_fence)) or_return
    deletion_queue_push(&self.deletion_queue, self.immediate_fence)

    return true
}

@(private = "file")
_init_descriptors :: proc(self: ^Engine) -> (ok: bool) {
    ratios := []Pool_Size_Ratio{{type = .STORAGE_IMAGE, ratio = 1.0}}

    self.global_descriptor_allocator = descriptor_pool_init(self.device, 10, ratios)

    // Make the descriptor set layout for the compute draw
    {
        builder := descriptor_layout_builder_init()
        defer descriptor_layout_builder_destroy(&builder)

        descriptor_layout_builder_add_binding(&builder, 0, .STORAGE_IMAGE)

        self.draw_image_descriptor_set_layout = descriptor_layout_builder_build(
            &builder,
            self.device,
            {.COMPUTE},
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

        writer := Descriptor_Writer{}
        descriptor_writer_write_image(
            &writer,
            0,
            self.draw_image.view,
            0,
            .GENERAL,
            .STORAGE_IMAGE,
        )
        descriptor_writer_update_set(&writer, self.device, self.draw_image_descriptor_set)
    }

    for &frame in self.frames {
        frame.frame_descriptors, ok = descriptor_growable_allocator_init(
            self.device,
            1000,
            []Pool_Size_Ratio {
                {type = .STORAGE_BUFFER, ratio = 3.0},
                {type = .STORAGE_IMAGE, ratio = 3.0},
                {type = .UNIFORM_BUFFER, ratio = 3.0},
                {type = .COMBINED_IMAGE_SAMPLER, ratio = 4.0},
            },
        )
        if !ok {
            log.error("Failed to create frame descriptor allocator")
            return false
        }
    }

    // Gpu scene data
    {
        builder := descriptor_layout_builder_init()
        descriptor_layout_builder_add_binding(&builder, 0, .UNIFORM_BUFFER)
        self.gpu_scene_data_descriptor_set_layout = descriptor_layout_builder_build(
            &builder,
            self.device,
            {.VERTEX, .FRAGMENT},
        )
        deletion_queue_push(&self.deletion_queue, self.gpu_scene_data_descriptor_set_layout)
    }

    // Single texture image
    {
        builder := descriptor_layout_builder_init()
        descriptor_layout_builder_add_binding(&builder, 0, .COMBINED_IMAGE_SAMPLER)
        self.single_image_descriptor_layout = descriptor_layout_builder_build(
            &builder,
            self.device,
            { .FRAGMENT },
        )
        deletion_queue_push(&self.deletion_queue, self.single_image_descriptor_layout)
    }

    return true
}

@(private = "file")
_init_pipelines :: proc(self: ^Engine) -> (ok: bool) {
    if !_init_background_pipelines(self) {
        log.error("Failed to initialize background compute pipelines")
        return false
    }

    return true
}

@(private = "file")
_init_background_pipelines :: proc(self: ^Engine) -> (ok: bool) {
    // Create gradient compute pipeline
    {
        // Create the layout

        compute_pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
            sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
            pSetLayouts            = &self.draw_image_descriptor_set_layout,
            setLayoutCount         = 1,
            pPushConstantRanges    = &vk.PushConstantRange {
                offset = 0,
                size = size_of(Compute_Push_Constants),
                stageFlags = {.COMPUTE},
            },
            pushConstantRangeCount = 1,
        }

        if !vk_check(
            vk.CreatePipelineLayout(
                self.device,
                &compute_pipeline_layout_create_info,
                nil,
                &self.gradient_pipeline_layout,
            ),
        ) {
            log.error("Failed to create gradient compute pipeline layout")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.gradient_pipeline_layout)

        // Load the shader module

        compute_shader_mod: vk.ShaderModule
        compute_shader_mod, ok = load_shader_module(self.device, "bin/shaders/gradient.comp.spv")
        if !ok {
            log.error("Failed to load gradient compute shader module")
            return false
        }
        defer vk.DestroyShaderModule(self.device, compute_shader_mod, nil)

        // Create the compute pipeline

        stage_create_info := vk.PipelineShaderStageCreateInfo {
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = {.COMPUTE},
            module = compute_shader_mod,
            pName  = "main",
        }

        compute_pipeline_create_info := vk.ComputePipelineCreateInfo {
            sType  = .COMPUTE_PIPELINE_CREATE_INFO,
            stage  = stage_create_info,
            layout = self.gradient_pipeline_layout,
        }

        if !vk_check(
            vk.CreateComputePipelines(
                self.device,
                0, // cache
                1,
                &compute_pipeline_create_info,
                nil,
                &self.gradient_pipeline,
            ),
        ) {
            log.error("Failed to create gradient compute pipeline")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.gradient_pipeline)

        log.infof("Gradient compute pipeline created successfully")
    }

    pipeline_builder := pipeline_builder_init()

    // Create the triangle pipeline
    {
        // Create the pipeline layout

        pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
            sType = .PIPELINE_LAYOUT_CREATE_INFO,
        }

        if !vk_check(
            vk.CreatePipelineLayout(
                self.device,
                &pipeline_layout_create_info,
                nil,
                &self.triangle_pipeline_layout,
            ),
        ) {
            log.error("Failed to create triangle pipeline layout")
            return false
        }
        deletion_queue_push(&self.deletion_queue, self.triangle_pipeline_layout)

        // Load the shader modules

        vertex_shader_mod: vk.ShaderModule
        vertex_shader_mod, ok = load_shader_module(
            self.device,
            "bin/shaders/colored_triangle.vert.spv",
        )
        if !ok {
            log.error("Failed to load triangle vertex shader module")
            return false
        }
        defer vk.DestroyShaderModule(self.device, vertex_shader_mod, nil)

        fragment_shader_mod: vk.ShaderModule
        fragment_shader_mod, ok = load_shader_module(
            self.device,
            "bin/shaders/colored_triangle.frag.spv",
        )
        if !ok {
            log.error("Failed to load triangle fragment shader module")
            return false
        }
        defer vk.DestroyShaderModule(self.device, fragment_shader_mod, nil)

        // Create the graphics pipeline

        pipeline_builder_set_shaders(
            &pipeline_builder,
            {
                {stage = .VERTEX, module = vertex_shader_mod},
                {stage = .FRAGMENT, module = fragment_shader_mod},
            },
        )

        pipeline_builder.pipeline_layout = self.triangle_pipeline_layout

        pipeline_builder_set_input_topology(&pipeline_builder, .TRIANGLE_LIST)
        pipeline_builder_set_polygon_mode(&pipeline_builder, .FILL)
        pipeline_builder_set_cull_mode(&pipeline_builder, {.BACK})
        pipeline_builder_disable_multisampling(&pipeline_builder)
        pipeline_builder_disable_blending(&pipeline_builder)
        pipeline_builder_set_color_attachment_format(&pipeline_builder, self.draw_image.format)
        pipeline_builder_enable_depth_test(&pipeline_builder, true, .GREATER_OR_EQUAL)
        pipeline_builder_set_depth_format(&pipeline_builder, self.depth_image.format)

        self.triangle_pipeline, ok = pipeline_builder_build(&pipeline_builder, self.device)
        if !ok {
            log.error("Failed to create triangle graphics pipeline")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.triangle_pipeline)
    }

    // Mesh pipeline
    {
        // Pipeline layout
        pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
            sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
            setLayoutCount         = 1,
            pSetLayouts            = &self.single_image_descriptor_layout,
            pushConstantRangeCount = 1,
            pPushConstantRanges    = &vk.PushConstantRange {
                stageFlags = {.VERTEX},
                offset = 0,
                size = size_of(Gpu_Draw_Push_Constants),
            },
        }
        if !vk_check(
            vk.CreatePipelineLayout(
                self.device,
                &pipeline_layout_create_info,
                nil,
                &self.mesh_pipeline_layout,
            ),
        ) {
            log.error("Failed to create mesh pipeline layout")
            return false
        }
        deletion_queue_push(&self.deletion_queue, self.mesh_pipeline_layout)

        // Shader modules
        vertex_shader_mod: vk.ShaderModule
        vertex_shader_mod, ok = load_shader_module(
            self.device,
            "bin/shaders/colored_triangle_mesh.vert.spv",
        )
        if !ok {
            log.error("Failed to load mesh vertex shader module")
            return false
        }
        defer vk.DestroyShaderModule(self.device, vertex_shader_mod, nil)

        fragment_shader_mod: vk.ShaderModule
        fragment_shader_mod, ok = load_shader_module(
            self.device,
            "bin/shaders/tex_image.frag.spv",
        )
        if !ok {
            log.error("Failed to load mesh fragment shader module")
            return false
        }
        defer vk.DestroyShaderModule(self.device, fragment_shader_mod, nil)

        // Create the mesh pipeline layout
        pipeline_builder_set_shaders(
            &pipeline_builder,
            {
                {stage = .VERTEX, module = vertex_shader_mod},
                {stage = .FRAGMENT, module = fragment_shader_mod},
            },
        )
        // pipeline_builder_enable_blending_additive(&pipeline_builder)
        pipeline_builder.pipeline_layout = self.mesh_pipeline_layout

        self.mesh_pipeline, ok = pipeline_builder_build(&pipeline_builder, self.device, 0)
        if !ok {
            log.error("Failed to create mesh graphics pipeline")
            return false
        }

        deletion_queue_push(&self.deletion_queue, self.mesh_pipeline)
    }

    // Create the UI pipeline
    {
        pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
            sType = .PIPELINE_LAYOUT_CREATE_INFO,
            setLayoutCount = 1,
            pSetLayouts = &self.single_image_descriptor_layout,
            pushConstantRangeCount = 1,
            pPushConstantRanges = &vk.PushConstantRange {
                stageFlags = {.VERTEX},
                offset = 0,
                size = size_of(vk.DeviceAddress),
            },
        }
        if !vk_check(
            vk.CreatePipelineLayout(
                self.device,
                &pipeline_layout_create_info,
                nil,
                &self.ui_pipeline_layout,
            ),
        ) {
            log.error("Failed to create UI pipeline layout")
            return false
        }
        deletion_queue_push(&self.deletion_queue, self.ui_pipeline_layout)

        // Load the shader modules
        vertex_shader_mod, fragment_shader_mod: vk.ShaderModule
        vertex_shader_mod, ok = load_shader_module(self.device, "bin/shaders/ui.vert.spv")
        if !ok { log.error("Failed to load UI vertex shader module"); return false }
        defer vk.DestroyShaderModule(self.device, vertex_shader_mod, nil)
        fragment_shader_mod, ok = load_shader_module(self.device, "bin/shaders/ui.frag.spv")
        if !ok { log.error("Failed to load UI fragment shader module"); return false }
        defer vk.DestroyShaderModule(self.device, fragment_shader_mod, nil)

        // Create the UI pipeline
        pipeline_builder_set_shaders(
            &pipeline_builder,
            {
                {stage = .VERTEX, module = vertex_shader_mod},
                {stage = .FRAGMENT, module = fragment_shader_mod},
            },
        )
        pipeline_builder.pipeline_layout = self.ui_pipeline_layout

        self.ui_pipeline, ok = pipeline_builder_build(&pipeline_builder, self.device)
        if !ok { log.error("Failed to create UI graphics pipeline"); return false }
        deletion_queue_push(&self.deletion_queue, self.ui_pipeline)
    }

    return true
}

@(private = "file")
_init_default_data :: proc(self: ^Engine) -> (ok: bool) {
    // Rectangle
    rect_vertices := [?]Vertex {
        {position = Vec3{0.5, -0.5, -1000}, uv_x = 0.0, color = Vec4{0.0, 0.0, 0.0, 1}, uv_y = 0.0},
        {position = Vec3{0.5,  0.5, -1000}, uv_x = 0.0, color = Vec4{0.5, 0.5, 0.5, 1}, uv_y = 0.0},
        {
            position = Vec3{-0.5, -0.5, 0.01},
            uv_x = 0.0,
            color = Vec4{1.0, 0.0, 0.0, 1},
            uv_y = 0.0,
        },
        {position = Vec3{-0.5, 0.5, 0.01}, uv_x = 0.0, color = Vec4{0.0, 1.0, 0.0, 1}, uv_y = 0.0},
    }

    rect_indices := [?]u32{0, 1, 2, 2, 1, 3}

    self.rectangle, ok = engine_upload_mesh(self, rect_indices[:], rect_vertices[:])
    assert(ok, "Failed to upload rectangle mesh")

    deletion_queue_push(&self.deletion_queue, self.rectangle.vertex_buffer)
    deletion_queue_push(&self.deletion_queue, self.rectangle.index_buffer)

    // Default textures
    white   := u32(0xFFFFFFFF)
    grey    := u32(0xFF808080)
    black   := u32(0xFF000000)
    magenta := u32(0xFFFF00FF)

    self.white_image = engine_create_image_with_data(
        self,
        mem.ptr_to_bytes(&white),
        vk.Extent3D{1, 1, 1},
        .R8G8B8A8_UNORM,
        { .SAMPLED },
    ) or_return
    deletion_queue_push(&self.deletion_queue, self.white_image)

    self.grey_image = engine_create_image_with_data(
        self,
        mem.ptr_to_bytes(&grey),
        vk.Extent3D{1, 1, 1},
        .R8G8B8A8_UNORM,
        { .SAMPLED },
    ) or_return
    deletion_queue_push(&self.deletion_queue, self.grey_image)

    self.black_image = engine_create_image_with_data(
        self,
        mem.ptr_to_bytes(&black),
        vk.Extent3D{1, 1, 1},
        .R8G8B8A8_UNORM,
        { .SAMPLED },
    ) or_return
    deletion_queue_push(&self.deletion_queue, self.black_image)

    magenta_data :[16*16]u32 = ---
    for y in 0..<16 {
        for x in 0..<16 {
            magenta_data[y * 16 + x] = magenta if ((x % 2) ~ (y % 2)) != 0 else black
        }
    }

    self.error_checkerboard_image = engine_create_image_with_data(
        self,
        mem.slice_to_bytes(magenta_data[:]),
        vk.Extent3D{16, 16, 1},
        .R8G8B8A8_UNORM,
        { .SAMPLED },
    ) or_return
    deletion_queue_push(&self.deletion_queue, self.error_checkerboard_image)

    // Create default samplers
    sampler_create_info := vk.SamplerCreateInfo{ sType = .SAMPLER_CREATE_INFO }

    sampler_create_info.minFilter = .NEAREST
    sampler_create_info.magFilter = .NEAREST
    vk.CreateSampler(self.device, &sampler_create_info, nil, &self.default_sampler_nearest)
    deletion_queue_push(&self.deletion_queue, self.default_sampler_nearest)

    sampler_create_info.minFilter = .LINEAR
    sampler_create_info.magFilter = .LINEAR
    vk.CreateSampler(self.device, &sampler_create_info, nil, &self.default_sampler_linear)
    deletion_queue_push(&self.deletion_queue, self.default_sampler_linear)

    UI_VERTEX_COUNT :: 1024 * 4
    UI_INDEX_COUNT  :: 1024 * 6

    // Create the UI vertex and index buffers
    {
        self.ui_vertex_buffer, ok = create_buffer(
            self,
            u64(UI_VERTEX_COUNT * size_of(Ui_Vertex)),
            { .VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS },
            .CPU_TO_GPU,
        )
        if !ok {
            log.error("Failed to create UI vertex buffer")
            return false
        }
        deletion_queue_push(&self.deletion_queue, self.ui_vertex_buffer)
        self.ui_vertex_buffer_address = vk.GetBufferDeviceAddress(
            self.device,
            &vk.BufferDeviceAddressInfo {
                sType  = .BUFFER_DEVICE_ADDRESS_INFO,
                buffer = self.ui_vertex_buffer.buffer,
            },
        )

        self.ui_index_buffer, ok = create_buffer(
            self,
            u64(UI_INDEX_COUNT * size_of(u32)),
            { .INDEX_BUFFER, .SHADER_DEVICE_ADDRESS },
            .CPU_TO_GPU,
        )
        if !ok {
            log.error("Failed to create UI index buffer")
            return false
        }
        deletion_queue_push(&self.deletion_queue, self.ui_index_buffer)
    }

    return true
}

@(private = "file")
_load_meshes :: proc(self: ^Engine) -> (ok: bool) {
    self.meshes, ok = loader_load_gltf_meshes(self, "assets/basicmesh.glb")

    if !ok {
        log.error("Failed to load meshes from glTF file")
        return false
    }

    for mesh in self.meshes {
        deletion_queue_push(&self.deletion_queue, mesh)
    }

    return true
}

engine_get_current_frame :: proc(self: ^Engine) -> (frame: ^Frame_Data) {
    frame_index := u32(self.frame_number % INFLIGHT_FRAME_OVERLAP)
    return &self.frames[frame_index]
}

//
// Deletion queue
//

Deletion_Queue :: struct {
    device:    vk.Device,
    resources: [dynamic]Delete_Resource,
}

Image_With_Allocator :: struct {
    image:     Allocated_Image,
    allocator: vma.Allocator,
}

Mesh_With_Allocator :: struct {
    vertex_buffer: Allocated_Buffer,
    index_buffer:  Allocated_Buffer,
    allocator:     vma.Allocator,
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
    Allocated_Image,
    Allocated_Buffer,
    Mesh_Asset,
}

deletion_queue_init :: proc(
    self: ^Deletion_Queue,
    device: vk.Device,
    allocator: runtime.Allocator = context.allocator,
) {
    self.device = device
    self.resources = make_dynamic_array_len_cap([dynamic]Delete_Resource, 0, 128, allocator)
}

deletion_queue_destroy :: proc(self: ^Deletion_Queue, engine: ^Engine) {
    assert(self != nil)
    deletion_queue_flush(self, engine)
    delete_dynamic_array(self.resources)
}

deletion_queue_push :: proc(self: ^Deletion_Queue, resource: Delete_Resource) {
    append(&self.resources, resource)
}

deletion_queue_flush :: proc(self: ^Deletion_Queue, engine: ^Engine) {
    assert(self != nil)
    #reverse for &resource in self.resources {
        switch &res in resource {
        case proc "c" ():
            res()
        case vk.Pipeline:
            vk.DestroyPipeline(self.device, res, nil)
        case vk.PipelineLayout:
            vk.DestroyPipelineLayout(self.device, res, nil)
        case vk.DescriptorSetLayout:
            vk.DestroyDescriptorSetLayout(self.device, res, nil)
        case vk.DescriptorPool:
            vk.DestroyDescriptorPool(self.device, res, nil)
        case vk.ImageView:
            vk.DestroyImageView(self.device, res, nil)
        case vk.Sampler:
            vk.DestroySampler(self.device, res, nil)
        case vk.CommandPool:
            vk.DestroyCommandPool(self.device, res, nil)
        case vk.Fence:
            vk.DestroyFence(self.device, res, nil)
        case vk.Semaphore:
            vk.DestroySemaphore(self.device, res, nil)
        case vk.Buffer:
            vk.DestroyBuffer(self.device, res, nil)
        case vk.DeviceMemory:
            vk.FreeMemory(self.device, res, nil)
        case vma.Allocator:
            vma.destroy_allocator(res)
        case Allocated_Image:
            engine_destroy_image(engine, res)
        case Allocated_Buffer:
            destroy_buffer(engine.allocator, &res)
        case Mesh_Asset:
            destroy_mesh_asset(engine, &res)
        case:
            assert(false, "Unknown resource type in deletion queue")
        }
    }
}

//
// Gradient shader push constants
//

Compute_Push_Constants :: struct {
    data1: Vec4,
    data2: Vec4,
    data3: Vec4,
    data4: Vec4,
}

engine_upload_mesh :: proc(
    self: ^Engine,
    indices: []u32,
    vertices: []Vertex,
) -> (
    mesh_buff: Gpu_Mesh_Buffers,
    ok: bool,
) {
    vb_size := len(vertices) * size_of(Vertex)
    ib_size := len(indices) * size_of(u32)

    new_surface: Gpu_Mesh_Buffers
    new_surface.vertex_buffer, ok = create_buffer(
        self,
        u64(vb_size),
        {.STORAGE_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS},
        .GPU_ONLY,
    )
    defer if !ok {
        destroy_buffer(self.allocator, &new_surface.vertex_buffer)
    }

    if !ok {
        log.error("")
        return
    }

    // Find the address of the vertex buffer
    device_addr_info := vk.BufferDeviceAddressInfo {
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = new_surface.vertex_buffer.buffer,
    }
    new_surface.vertex_buffer_address = vk.GetBufferDeviceAddress(self.device, &device_addr_info)

    // Create the index buffer
    new_surface.index_buffer, ok = create_buffer(
        self,
        u64(ib_size),
        {.INDEX_BUFFER, .TRANSFER_DST},
        .GPU_ONLY,
    )
    defer if !ok {
        destroy_buffer(self.allocator, &new_surface.index_buffer)
    }

    // Upload the data to the buffer
    staging_buffer: Allocated_Buffer
    staging_buffer, ok = create_buffer(self, u64(vb_size + ib_size), {.TRANSFER_SRC}, .CPU_ONLY)
    defer destroy_buffer(self.allocator, &staging_buffer)

    Copy_Info :: struct {
        staging_buffer:     vk.Buffer,
        vertex_buffer:      vk.Buffer,
        index_buffer:       vk.Buffer,
        vertex_buffer_size: vk.DeviceSize,
        index_buffer_size:  vk.DeviceSize,
    }

    copy_info := Copy_Info {
        staging_buffer     = staging_buffer.buffer,
        vertex_buffer      = new_surface.vertex_buffer.buffer,
        index_buffer       = new_surface.index_buffer.buffer,
        vertex_buffer_size = vk.DeviceSize(vb_size),
        index_buffer_size  = vk.DeviceSize(ib_size),
    }

    intr.mem_copy(staging_buffer.info.mapped_data, raw_data(vertices), vb_size)
    intr.mem_copy(
        rawptr(uintptr(staging_buffer.info.mapped_data) + uintptr(vb_size)),
        raw_data(indices),
        ib_size,
    )

    _immediate_submit(self, &copy_info, proc(_: ^Engine, cmd: vk.CommandBuffer, data: ^Copy_Info) {
        vertex_copy := vk.BufferCopy {
            srcOffset = 0,
            dstOffset = 0,
            size      = data.vertex_buffer_size,
        }
        vk.CmdCopyBuffer(cmd, data.staging_buffer, data.vertex_buffer, 1, &vertex_copy)

        index_copy := vk.BufferCopy {
            srcOffset = data.vertex_buffer_size,
            dstOffset = 0,
            size      = data.index_buffer_size,
        }
        vk.CmdCopyBuffer(cmd, data.staging_buffer, data.index_buffer, 1, &index_copy)
    })

    return new_surface, true
}
