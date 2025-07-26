package vkguide

import "core:fmt"
import vk "vendor:vulkan"

MAX_SHADER_STAGES :: 5

Pipeline_Builder :: struct {
    shader_stages:              [MAX_SHADER_STAGES]vk.PipelineShaderStageCreateInfo,
    shader_stages_count:        u32,
    input_assembly:             vk.PipelineInputAssemblyStateCreateInfo,
    rasterizer:                 vk.PipelineRasterizationStateCreateInfo,
    color_blend_attachment:     vk.PipelineColorBlendAttachmentState,
    multisampling:              vk.PipelineMultisampleStateCreateInfo,
    pipeline_layout:            vk.PipelineLayout,
    depth_stencil:              vk.PipelineDepthStencilStateCreateInfo,
    render_info:                vk.PipelineRenderingCreateInfo,
    color_attachment_format:    vk.Format,
}

Shader_Stage :: struct {
    module: vk.ShaderModule,
    stage:  vk.ShaderStageFlag,
}

pipeline_builder_init :: proc() -> Pipeline_Builder {
    return Pipeline_Builder{
        input_assembly         = { sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,  },
        rasterizer             = { sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,   },
        color_blend_attachment = {},
        multisampling          = { sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,     },
        pipeline_layout        = 0,
        depth_stencil          = { sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,   },
        render_info            = { sType = .PIPELINE_RENDERING_CREATE_INFO,             },
    }
}

pipeline_builder_build :: proc(
    self: ^Pipeline_Builder,
    device: vk.Device,
    cache: vk.PipelineCache = 0,
) -> (pipeline: vk.Pipeline, ok: bool) {
    viewport_state := vk.PipelineViewportStateCreateInfo{
        sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        scissorCount  = 1,
    }

    color_blend_state := vk.PipelineColorBlendStateCreateInfo{
        sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable   = false,
        attachmentCount = 1,
        pAttachments    = &self.color_blend_attachment,
    }

    vertex_input_state := vk.PipelineVertexInputStateCreateInfo{
        sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }

    dynamic_states := []vk.DynamicState{ .VIEWPORT, .SCISSOR }
    dynamic_state := vk.PipelineDynamicStateCreateInfo{
        sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        dynamicStateCount = u32(len(dynamic_states)),
        pDynamicStates    = raw_data(dynamic_states),
    }

    pipeline_info := vk.GraphicsPipelineCreateInfo{
        sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext               = &self.render_info,
        stageCount          = self.shader_stages_count,
        pStages             = &self.shader_stages[0],
        pVertexInputState   = &vertex_input_state,
        pInputAssemblyState = &self.input_assembly,
        pViewportState      = &viewport_state,
        pRasterizationState = &self.rasterizer,
        pMultisampleState   = &self.multisampling,
        pColorBlendState    = &color_blend_state,
        pDepthStencilState  = &self.depth_stencil,
        layout              = self.pipeline_layout,
        pDynamicState       = &dynamic_state,
    }

    vk_check(vk.CreateGraphicsPipelines(
        device,
        cache,
        1,
        &pipeline_info,
        nil,
        &pipeline,
    )) or_return

    ok = true
    return
}

pipeline_builder_set_shaders :: proc(self: ^Pipeline_Builder, stages: []Shader_Stage) {
    _check_shader_stages_are_valid(stages)

    for i in 0 ..< len(stages) {
        self.shader_stages[i] = vk.PipelineShaderStageCreateInfo{
            sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage  = { stages[i].stage },
            module = stages[i].module,
            pName  = "main",
        }
    }
    self.shader_stages_count = u32(len(stages))
}

@(private="file", disabled=!ODIN_DEBUG)
_check_shader_stages_are_valid :: proc(stages: []Shader_Stage, loc := #caller_location) {
    assert(len(stages) > 0, "No shader stages provided", loc)
    assert(len(stages) <= MAX_SHADER_STAGES, "Too many shader stages", loc)
    stage_flags := vk.ShaderStageFlags{}
    for stage in stages {
        assert(!(stage.stage in stage_flags), fmt.tprintf("Duplicate shader stage %v found", stage.stage), loc)
        assert(
            stage.stage != .COMPUTE || stage_flags == {},
            "Compute shader stage cannot be combined with other stages",
            loc,
        )
        stage_flags += { stage.stage }
    }
}

pipeline_builder_set_input_topology :: proc(self: ^Pipeline_Builder, topology: vk.PrimitiveTopology) {
    self.input_assembly.topology               = topology
    self.input_assembly.primitiveRestartEnable = false
}

pipeline_builder_set_polygon_mode :: proc(self: ^Pipeline_Builder, mode: vk.PolygonMode) {
    self.rasterizer.polygonMode = mode
    self.rasterizer.lineWidth = 1.0 // @TODO: make this configurable (needs an extension)
}

pipeline_builder_set_cull_mode :: proc(
    self: ^Pipeline_Builder,
    mode: vk.CullModeFlags,
    winding: vk.FrontFace = .COUNTER_CLOCKWISE,
) {
    self.rasterizer.cullMode        = mode
    self.rasterizer.frontFace       = winding
    self.rasterizer.depthBiasEnable = false
}

pipeline_builder_disable_multisampling :: proc(self: ^Pipeline_Builder) {
    self.multisampling.rasterizationSamples = { ._1 }
    self.multisampling.sampleShadingEnable  = false
    self.multisampling.minSampleShading     = 1.0
    self.multisampling.pSampleMask          = nil
    self.multisampling.alphaToCoverageEnable = false
    self.multisampling.alphaToOneEnable     = false
}

pipeline_builder_disable_blending :: proc(self: ^Pipeline_Builder) {
    self.color_blend_attachment.blendEnable = false
    self.color_blend_attachment.colorWriteMask = { .R, .G, .B, .A }
}

pipeline_builder_enable_blending_additive :: proc(self: ^Pipeline_Builder) {
    self.color_blend_attachment.colorWriteMask      = { .R, .G, .B, .A }
    self.color_blend_attachment.blendEnable         = true
    self.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
    self.color_blend_attachment.dstColorBlendFactor = .ONE
    self.color_blend_attachment.colorBlendOp        = .ADD
    self.color_blend_attachment.srcAlphaBlendFactor = .ONE
    self.color_blend_attachment.dstAlphaBlendFactor = .ZERO
    self.color_blend_attachment.alphaBlendOp        = .ADD
}

pipeline_builder_enable_blending_alphablend :: proc(self: ^Pipeline_Builder) {
    self.color_blend_attachment.colorWriteMask      = { .R, .G, .B, .A }
    self.color_blend_attachment.blendEnable         = true
    self.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
    self.color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
    self.color_blend_attachment.colorBlendOp        = .ADD
    self.color_blend_attachment.srcAlphaBlendFactor = .ONE
    self.color_blend_attachment.dstAlphaBlendFactor = .ZERO
    self.color_blend_attachment.alphaBlendOp        = .ADD
}

pipeline_builder_set_color_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format) {
    self.color_attachment_format             = format
    self.render_info.colorAttachmentCount    = 1
    self.render_info.pColorAttachmentFormats = &self.color_attachment_format
}

pipeline_builder_set_depth_format :: proc(self: ^Pipeline_Builder, format: vk.Format) {
    self.render_info.depthAttachmentFormat   = format
}

pipeline_builder_disable_depth_test :: proc(self: ^Pipeline_Builder) {
    self.depth_stencil.depthTestEnable       = false
    self.depth_stencil.depthWriteEnable      = false
    self.depth_stencil.depthCompareOp        = .NEVER
    self.depth_stencil.stencilTestEnable     = false
    self.depth_stencil.depthBoundsTestEnable = false
    self.depth_stencil.front                 = {}
    self.depth_stencil.back                  = {}
    self.depth_stencil.minDepthBounds        = 0.0
    self.depth_stencil.maxDepthBounds        = 1.0
}

pipeline_builder_enable_depth_test :: proc(
    self: ^Pipeline_Builder,
    write_enabled: bool,
    compare_op: vk.CompareOp = .LESS,
) {
    self.depth_stencil.depthTestEnable       = true
    self.depth_stencil.depthWriteEnable      = b32(write_enabled)
    self.depth_stencil.depthCompareOp        = compare_op
    self.depth_stencil.stencilTestEnable     = false
    self.depth_stencil.depthBoundsTestEnable = false
    self.depth_stencil.front                 = {}
    self.depth_stencil.back                  = {}
    self.depth_stencil.minDepthBounds        = 0.0
    self.depth_stencil.maxDepthBounds        = 1.0
}

//
// Tests
//

import "core:testing"

@(test)
_test_shader_stages_1 :: proc(t: ^testing.T) {
    pipeline_builder := pipeline_builder_init()
    testing.expect_assert_message(t, "Duplicate shader stage VERTEX found")
    pipeline_builder_set_shaders(&pipeline_builder, {
        Shader_Stage{ module = 0, stage = .VERTEX },
        Shader_Stage{ module = 0, stage = .VERTEX },
    })
}

@(test)
_test_shader_stages_2 :: proc(t: ^testing.T) {
    pipeline_builder := pipeline_builder_init()
    testing.expect_assert_message(t, "No shader stages provided")
    pipeline_builder_set_shaders(&pipeline_builder, {})
}

@(test)
_test_shader_stages_3 :: proc(t: ^testing.T) {
    pipeline_builder := pipeline_builder_init()
    testing.expect_assert_message(t, "Compute shader stage cannot be combined with other stages")
    pipeline_builder_set_shaders(&pipeline_builder, {
        Shader_Stage{ module = 0, stage = .VERTEX },
        Shader_Stage{ module = 0, stage = .FRAGMENT },
        Shader_Stage{ module = 0, stage = .COMPUTE },
    })
}

@(test)
_test_shader_stages_4 :: proc(t: ^testing.T) {
    pipeline_builder := pipeline_builder_init()
    pipeline_builder_set_shaders(&pipeline_builder, {
        Shader_Stage{ module = 0, stage = .VERTEX },
        Shader_Stage{ module = 0, stage = .FRAGMENT },
        Shader_Stage{ module = 0, stage = .MESH_EXT },
    })
}

