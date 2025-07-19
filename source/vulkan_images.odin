package vkguide

import vk "vendor:vulkan"

vkutil_transition_image :: proc(cmd: vk.CommandBuffer, image: vk.Image, current_layout, new_layout: vk.ImageLayout) {
    is_depth :=
        (new_layout == .DEPTH_STENCIL_ATTACHMENT_OPTIMAL || current_layout == .DEPTH_ATTACHMENT_OPTIMAL)

    image_barrier := vk.ImageMemoryBarrier2{
        sType = .IMAGE_MEMORY_BARRIER_2,
        pNext = nil,
        srcStageMask = { .ALL_COMMANDS },
        srcAccessMask = { .MEMORY_WRITE },
        dstStageMask = { .ALL_COMMANDS },
        dstAccessMask = { .MEMORY_READ, .MEMORY_WRITE },
        oldLayout = current_layout,
        newLayout = new_layout,
        subresourceRange = init_subresource_range({ .DEPTH } if is_depth else { .COLOR }),
        image = image,
    }

    dependency_info := vk.DependencyInfo{
        sType = .DEPENDENCY_INFO,
        pNext = nil,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers = &image_barrier,
    }

    vk.CmdPipelineBarrier2(cmd, &dependency_info)
}

