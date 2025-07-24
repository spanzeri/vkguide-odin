package vkguide

import vk "vendor:vulkan"

init_command_pool_crate_info :: proc(
    queue_family_index: u32,
    flags: vk.CommandPoolCreateFlags = {},
) -> vk.CommandPoolCreateInfo {
    return vk.CommandPoolCreateInfo{
        sType = .COMMAND_POOL_CREATE_INFO,
        pNext = nil,
        queueFamilyIndex = queue_family_index,
        flags = flags,
    }
}

init_command_buffer_allocate_info :: proc(pool: vk.CommandPool, count: u32) -> vk.CommandBufferAllocateInfo {
    return vk.CommandBufferAllocateInfo{
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        pNext = nil,
        commandPool = pool,
        level = .PRIMARY,
        commandBufferCount = count,
    }
}

init_fence_create_info :: proc(flags: vk.FenceCreateFlags = {}) -> vk.FenceCreateInfo {
    return vk.FenceCreateInfo{
        sType = .FENCE_CREATE_INFO,
        pNext = nil,
        flags = flags,
    }
}

init_semaphore_create_info :: proc() -> vk.SemaphoreCreateInfo {
    return vk.SemaphoreCreateInfo{
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = nil,
        flags = {},
    }
}

init_command_buffer_begin_info :: proc(flags := vk.CommandBufferUsageFlags{}) -> vk.CommandBufferBeginInfo {
    return vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        pNext = nil,
        flags = flags,
        pInheritanceInfo = nil,
    }
}

init_subresource_range :: proc(aspect_mask := vk.ImageAspectFlags{}) -> vk.ImageSubresourceRange {
    return vk.ImageSubresourceRange{
        aspectMask = aspect_mask,
        baseMipLevel = 0,
        levelCount = vk.REMAINING_MIP_LEVELS,
        baseArrayLayer = 0,
        layerCount = vk.REMAINING_ARRAY_LAYERS,
    }
}

init_semaphore_submit_info :: proc(stage_mask: vk.PipelineStageFlags2, semaphore: vk.Semaphore) -> vk.SemaphoreSubmitInfo {
    return vk.SemaphoreSubmitInfo{
        sType = .SEMAPHORE_SUBMIT_INFO,
        pNext = nil,
        stageMask = stage_mask,
        semaphore = semaphore,
        value = 1,
    }
}

init_command_buffer_submit_info :: proc(cmd: vk.CommandBuffer) -> vk.CommandBufferSubmitInfo {
    return vk.CommandBufferSubmitInfo{
        sType = .COMMAND_BUFFER_SUBMIT_INFO,
        pNext = nil,
        commandBuffer = cmd,
        deviceMask = 0,
    }
}

init_submit_info :: proc(
    cmd_buffer_submit_info: ^vk.CommandBufferSubmitInfo,
    signal_semaphore_info: ^vk.SemaphoreSubmitInfo,
    wait_semaphore_info: ^vk.SemaphoreSubmitInfo,
) -> vk.SubmitInfo2 {
    return vk.SubmitInfo2{
        sType = .SUBMIT_INFO_2,
        pNext = nil,
        waitSemaphoreInfoCount = 1,
        pWaitSemaphoreInfos = wait_semaphore_info,
        commandBufferInfoCount = 1,
        pCommandBufferInfos = cmd_buffer_submit_info,
        signalSemaphoreInfoCount = 1,
        pSignalSemaphoreInfos = signal_semaphore_info,
    }
}

init_image_create_info :: proc(
    format: vk.Format,
    usage_flags: vk.ImageUsageFlags,
    extent: vk.Extent3D,
) -> vk.ImageCreateInfo {
    return vk.ImageCreateInfo{
        sType       = .IMAGE_CREATE_INFO,
        pNext       = nil,
        imageType   = .D2,
        format      = format,
        extent      = extent,
        mipLevels   = 1,
        arrayLayers = 1,
        samples     = { ._1 },
        tiling      = .OPTIMAL,
        usage       = usage_flags,
    }
}

init_image_view_create_info :: proc(
    format: vk.Format,
    image: vk.Image,
    aspect_flags: vk.ImageAspectFlags,
) -> vk.ImageViewCreateInfo {
    return vk.ImageViewCreateInfo{
        sType       = .IMAGE_VIEW_CREATE_INFO,
        pNext       = nil,
        viewType    = .D2,
        image       = image,
        format      = format,
        subresourceRange = {
            baseMipLevel    = 0,
            levelCount      = 1,
            baseArrayLayer  = 0,
            layerCount      = 1,
            aspectMask      = aspect_flags,
        },
    }
}

init_rendering_attachment_info :: proc(
    view: vk.ImageView,
    clear: Maybe(vk.ClearValue),
    layout := vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
) -> vk.RenderingAttachmentInfo {
    info := vk.RenderingAttachmentInfo{
        sType       = .RENDERING_ATTACHMENT_INFO,
        pNext       = nil,
        imageView   = view,
        imageLayout = layout,
        storeOp     = .STORE,
    }

    if clear_value, ok := clear.?; ok {
        info.loadOp = .CLEAR
        info.clearValue = clear_value
    } else {
        info.loadOp = .LOAD
        info.clearValue = vk.ClearValue{}
    }

    return info
}

init_rendering_info :: proc(
    extent: vk.Extent2D,
    color_attachment: ^vk.RenderingAttachmentInfo,
    depth_attachment: ^vk.RenderingAttachmentInfo,
) -> vk.RenderingInfo {
    return vk.RenderingInfo{
        sType                = .RENDERING_INFO,
        renderArea = {
            offset = { 0, 0 },
            extent = extent,
        },
        layerCount           = 1,
        colorAttachmentCount = 1,
        pColorAttachments    = color_attachment,
        pDepthAttachment     = depth_attachment,
        pStencilAttachment   = nil,
    }
}
