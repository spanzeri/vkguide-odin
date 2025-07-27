package vkguide

import vk "vendor:vulkan"
import vma "lib:vma"

Allocated_Image :: struct {
    image:      vk.Image,
    view:       vk.ImageView,
    allocation: vma.Allocation,
    extent:     vk.Extent3D,
    format:     vk.Format,
}

image_transition :: proc(cmd: vk.CommandBuffer, image: vk.Image, current_layout, new_layout: vk.ImageLayout) {
    is_depth :=
        (new_layout == .DEPTH_STENCIL_ATTACHMENT_OPTIMAL || current_layout == .DEPTH_ATTACHMENT_OPTIMAL)

    image_barrier := vk.ImageMemoryBarrier2{
        sType            = .IMAGE_MEMORY_BARRIER_2,
        pNext            = nil,
        srcStageMask     = { .ALL_COMMANDS },
        srcAccessMask    = { .MEMORY_WRITE },
        dstStageMask     = { .ALL_COMMANDS },
        dstAccessMask    = { .MEMORY_READ, .MEMORY_WRITE },
        oldLayout        = current_layout,
        newLayout        = new_layout,
        subresourceRange = init_subresource_range({ .DEPTH } if is_depth else { .COLOR }),
        image            = image,
    }

    dependency_info := vk.DependencyInfo{
        sType = .DEPENDENCY_INFO,
        pNext = nil,
        imageMemoryBarrierCount = 1,
        pImageMemoryBarriers = &image_barrier,
    }

    vk.CmdPipelineBarrier2(cmd, &dependency_info)
}

copy_image_to_image :: proc(
    cmd: vk.CommandBuffer,
    src_image: vk.Image,
    dst_image: vk.Image,
    src_extent: vk.Extent2D,
    dst_extent: vk.Extent2D,
) {
    blit_region := vk.ImageBlit2{
        sType = .IMAGE_BLIT_2,
        srcOffsets = {
            { 0, 0, 0 },
            { i32(src_extent.width), i32(src_extent.height), 1 },
        },
        dstOffsets = {
            { 0, 0, 0 },
            { i32(src_extent.width), i32(src_extent.height), 1 },
        },
        srcSubresource = {
            aspectMask     = { .COLOR },
            baseArrayLayer = 0,
            layerCount     = 1,
            mipLevel       = 0,
        },
        dstSubresource = {
            aspectMask     = { .COLOR },
            baseArrayLayer = 0,
            layerCount     = 1,
            mipLevel       = 0,
        },
    }

    blit_info := vk.BlitImageInfo2{
        sType = .BLIT_IMAGE_INFO_2,
        dstImage = dst_image,
        srcImage = src_image,
        dstImageLayout = .TRANSFER_DST_OPTIMAL,
        srcImageLayout = .TRANSFER_SRC_OPTIMAL,
        filter = .LINEAR,
        regionCount = 1,
        pRegions = &blit_region,
    }

    vk.CmdBlitImage2(cmd, &blit_info)
}
