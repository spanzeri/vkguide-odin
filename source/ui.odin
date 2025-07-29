/**

Instead of using dearimgui (which is an excellent library), we leverage the
libraries that odin ships with: microui and stb_truetype.

stb_truetype generates a font atlas at runtime. For a real application, a tool
should be used to generate a font offline, but this is plenty fast for an
experiment or even for a simple game.
It is based on microui and stb_truetype.

microui is used for layout and behaviour.

SDL will provide the input bindings.

*/

package vkguide

import "base:runtime"
import "core:log"
import "core:os"
import mu "vendor:microui"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"
import sttb "vendor:stb/truetype"

Ui_Config :: struct {
    font_path: string,
    font_size: int,
}

Ui_Context :: ^mu.Context

Ui_Font :: struct {
    info:         sttb.fontinfo,
    chardata:     []sttb.packedchar,
    first_char:   i32,
    last_char:    i32,
    scale:        f32,
    baseline:     u16,
    line_height:  u16,
    font_size:    i32,
    texture:      Allocated_Image,
}

ui_init :: proc(ui_config: Ui_Config, engine: ^Engine) -> (ui_context: Ui_Context, ok: bool) {
    ui_context = new(mu.Context)
    defer if !ok { free(ui_context) }

    ui_font := new(Ui_Font)
    defer if !ok { free(ui_font) }

    ui_font^, ok = ui_font_create(
        Font_Load_Config{
            path = ui_config.font_path,
            font_size = i32(ui_config.font_size),
            image_size = { 512, 512 },
        },
        engine,
    )
    if !ok {
        log.errorf("Failed to create font from config: %s", ui_config.font_path)
        return
    }

    mu.init(ui_context)
    ui_context.text_width  = ui_font_get_text_width
    ui_context.text_height = ui_font_get_text_height
    ui_context.style.font = cast(mu.Font)ui_font

    log.infof("UI initialized successfully with font: %s", ui_config.font_path)
    return ui_context, true
}

ui_shutdown :: proc(ui_context: Ui_Context, engine: ^Engine) {
    font := cast(^Ui_Font)ui_context.style.font

    ui_font_destroy(font, engine)
    free(font)
    free(ui_context)
}

ui_update_input :: proc(ui_context: Ui_Context, event: ^sdl.Event) {
    #partial switch event.type {
    case .MOUSE_MOTION:
        mu.input_mouse_move(ui_context, i32(event.motion.x), i32(event.motion.y))
    case .MOUSE_BUTTON_UP, .MOUSE_BUTTON_DOWN:
        mouse_button :mu.Mouse
        switch event.button.button {
        case 1: mouse_button = .LEFT
        case 2: mouse_button = .RIGHT
        case 3: mouse_button = .MIDDLE
        }

        if event.type == .MOUSE_BUTTON_DOWN {
            mu.input_mouse_down(ui_context, i32(event.button.x), i32(event.button.y), mouse_button)
        } else {
            mu.input_mouse_up(ui_context, i32(event.button.x), i32(event.button.y), mouse_button)
        }
    }
}

ui_begin :: proc(ui_context: Ui_Context) {
    mu.begin(ui_context)
}

ui_end :: proc(ui_context: Ui_Context) {
    mu.end(ui_context)
}

ui_demo :: proc(ui_context: Ui_Context) {
    if mu.begin_window(ui_context, "Demo window", { 100, 100, 300, 240 }, {}) {
        mu.label(ui_context, "This is a demo window.")
    }
    mu.end_window(ui_context)
}

/*======================================

    Fonts

======================================*/

@(private="file")
ui_font_get_text_width :: proc(font: mu.Font, text: string) -> i32 {
    ui_font := cast(^Ui_Font)font
    if len(text) == 0 {
        return 0
    }

    x, y: f32 = 0.0, 0.0
    for tc, i in text {
        c := i32(tc)
        if i32(c) < ui_font.first_char || i32(c) > ui_font.last_char {
            c = '?'
        }

        ftw := i32(ui_font.texture.extent.width)
        fth := i32(ui_font.texture.extent.height)
        quad :sttb.aligned_quad
        sttb.GetPackedQuad(&ui_font.chardata[0], ftw, fth, c - ui_font.first_char, &x, &y, &quad, true)

        if i + 1 < len(text) && ui_font.info.kern != 0 {
            x += ui_font.scale * f32(sttb.GetCodepointKernAdvance(&ui_font.info, rune(c), rune(text[i + 1])))
        }
    }

    return i32(x + 0.5)
}

@(private="file")
ui_font_get_text_height :: proc(font: mu.Font) -> i32 {
    ui_font := cast(^Ui_Font)font
    return i32(ui_font.line_height)
}

@(private="file")
Font_Load_Config :: struct {
    path: string,
    font_size: i32,
    image_size: [2]i32,
}

@(private="file")
ui_font_create :: proc(fl_config: Font_Load_Config, engine: ^Engine) -> (finfo: Ui_Font, ok: bool) {
    font_data: []byte
    font_data, ok = os.read_entire_file_from_filename(fl_config.path, context.temp_allocator)
    if !ok {
        log.errorf("Failed to read font file: %s", fl_config.path)
        return
    }

    font_info: sttb.fontinfo
    if !sttb.InitFont(&font_info, raw_data(font_data), 0) {
        log.errorf("Failed to initialize font from data")
        return
    }

    scale := sttb.ScaleForPixelHeight(&font_info, f32(fl_config.font_size))
    ascent, descent, line_gap: i32
    sttb.GetFontVMetrics(&font_info, &ascent, &descent, &line_gap)

    baseline := u16(f32(ascent) * scale)
    line_height := u16(f32(ascent - descent + line_gap) * scale)

    pixels, alloc_err := make_slice([]u8, fl_config.image_size.x * fl_config.image_size.y)
    if alloc_err != .None {
        log.errorf("Failed to allocate memory for font atlas: %v", alloc_err)
        return
    }
    defer delete_slice(pixels)

    pc: sttb.pack_context
    res := sttb.PackBegin(&pc, &pixels[0], fl_config.image_size.x, fl_config.image_size.y, 0, 2, nil)
    if res == 0 {
        log.errorf("Failed to begin packing font atlas: %v", res)
        return
    }

    first_char := i32(32)
    last_char := i32(126)
    chardata: []sttb.packedchar
    chardata, alloc_err = make_slice([]sttb.packedchar, last_char - first_char + 1)
    if alloc_err != .None {
        log.errorf("Failed to allocate memory for character data: %v", alloc_err)
        return
    }
    defer if !ok {
        delete_slice(chardata)
    }

    sttb.PackSetOversampling(&pc, 2, 2)
    sttb.PackFontRange(
        &pc,
        raw_data(font_data),
        0,
        f32(fl_config.font_size),
        first_char,
        last_char - first_char +1,
        &chardata[0],
    )

    sttb.PackEnd(&pc)

    font_atlas := engine_create_image_with_data(
        engine,
        pixels,
        { u32(fl_config.image_size.x), u32(fl_config.image_size.y), 1 },
        .R8_UNORM,
        { .SAMPLED },
    ) or_return

    finfo = Ui_Font{
        info         = font_info,
        chardata     = chardata,
        first_char   = i32(first_char),
        last_char    = i32(last_char),
        scale        = scale,
        baseline     = baseline,
        line_height  = line_height,
        font_size    = fl_config.font_size,
        texture      = font_atlas,
    }

    return finfo, true
}

@(private="file")
ui_font_destroy :: proc(font: ^Ui_Font, engine: ^Engine) {
    vk.DeviceWaitIdle(engine.device)
    if font.texture.image != 0 {
        engine_destroy_image(engine, font.texture)
    }
    delete_slice(font.chardata)
}

Ui_Draw_Call :: struct {
    index_offset: i32,
    index_count: i32,
}

Ui_Draw_Context :: struct {
    engine:         ^Engine,
    cmd:            vk.CommandBuffer,
    vertices:       []Ui_Vertex,
    indices:        []u32,
    vertex_count:   i32,
    index_count:    i32,
    start_index:    i32,

    draw_calls: [dynamic]Ui_Draw_Call,
}

ui_render_context_init :: proc(engine: ^Engine, cmd: vk.CommandBuffer) -> Ui_Draw_Context {
    res := Ui_Draw_Context{ engine = engine, cmd = cmd }

    assert(engine.ui_vertex_buffer.info.mapped_data != nil)
    assert(engine.ui_index_buffer.info.mapped_data != nil)

    vertices := cast([^]Ui_Vertex)(engine.ui_vertex_buffer.info.mapped_data)
    vertex_count := engine.ui_vertex_buffer.info.size / size_of(Ui_Vertex)
    res.vertices = vertices[0:vertex_count]

    indices := cast([^]u32)(engine.ui_index_buffer.info.mapped_data)
    index_count := engine.ui_index_buffer.info.size / size_of(u32)
    res.indices = indices[0:index_count]

    res.vertex_count = 0
    res.index_count = 0
    res.start_index = 0

    alloc_err :runtime.Allocator_Error
    res.draw_calls = make_dynamic_array_len_cap(
        [dynamic] Ui_Draw_Call,
        0,
        64,
        context.temp_allocator,
    )
    assert(alloc_err == .None)

    return res
}

ui_render_context_render :: proc(ui_ctx: ^mu.Context, draw_ctx: ^Ui_Draw_Context) -> bool {
    mu_cmd: ^mu.Command
    for mu.next_command(ui_ctx, &mu_cmd) {
        #partial switch cmd in mu_cmd.variant {
        case ^mu.Command_Clip:
            ui_render_context_flush(draw_ctx)
            ui_render_context_set_scissor(draw_ctx, cmd.rect)
        case ^mu.Command_Text:
            // ui_render_context_draw_text(ctx, cast(^Ui_Font)cmd.font, cmd.text, cmd.pos, cmd.color)
        case ^mu.Command_Rect:
            x := (f32(cmd.rect.x) / f32(draw_ctx.engine.draw_image_extent.width)) * 2.0 - 1.0
            y := (f32(cmd.rect.y) / f32(draw_ctx.engine.draw_image_extent.height)) * 2.0 - 1.0
            w := (f32(cmd.rect.w) / f32(draw_ctx.engine.draw_image_extent.width)) * 2.0
            h := (f32(cmd.rect.h) / f32(draw_ctx.engine.draw_image_extent.height)) * 2.0
            ui_push_quad(draw_ctx, x, y, w, h, { 0, 0 }, { 1, 1 }, cmd.color, false)

        case ^mu.Command_Icon:
        case:
            assert(false, "Unknown command type in UI render context")
        }
    }

    cmd := draw_ctx.cmd
    vk.CmdBindPipeline(cmd, .GRAPHICS, draw_ctx.engine.ui_pipeline)
    frame := engine_get_current_frame(draw_ctx.engine)
    image_set := descriptor_growable_allocator_allocate(
        &frame.frame_descriptors,
        draw_ctx.engine.single_image_descriptor_layout,
    )
    writer := Descriptor_Writer{}
    font := cast(^Ui_Font)ui_ctx.style.font
    descriptor_writer_write_image(
        &writer,
        0,
        font.texture.view,
        draw_ctx.engine.default_sampler_linear,
    )
    descriptor_writer_update_set(&writer, draw_ctx.engine.device, image_set)

    vk.CmdBindDescriptorSets(cmd, .GRAPHICS, draw_ctx.engine.ui_pipeline_layout, 0, 1, &image_set, 0, nil)

    vk.CmdPushConstants(
        cmd,
        draw_ctx.engine.ui_pipeline_layout,
        { .VERTEX },
        0,
        size_of(vk.DeviceAddress),
        &draw_ctx.engine.ui_vertex_buffer_address,
    )

    vk.CmdBindIndexBuffer(cmd, draw_ctx.engine.ui_index_buffer.buffer, 0, .UINT32)

    for i in 0 ..< len(draw_ctx.draw_calls) {
        vk.CmdDrawIndexed(
            cmd,
            u32(draw_ctx.draw_calls[i].index_count),
            1,
            u32(draw_ctx.draw_calls[i].index_offset),
            0,
            0,
        )
    }

    return true
}

ui_convert_color :: proc(color: mu.Color) -> Vec3 {
    return Vec3{ f32(color.r) / 255.0, f32(color.g) / 255.0, f32(color.b) / 255.0 }
}

ui_render_context_flush :: proc(ctx: ^Ui_Draw_Context) {
    if ctx.vertex_count == 0 || ctx.index_count == 0 {
        return
    }

    index_count := ctx.index_count - ctx.start_index
    if index_count <= 0 { return }

    append_elem(&ctx.draw_calls, Ui_Draw_Call{ index_offset = ctx.start_index, index_count = index_count })
    ctx.start_index = ctx.index_count
}

ui_render_context_set_scissor :: proc(ctx: ^Ui_Draw_Context, rect: mu.Rect) {
    cmd := engine_get_current_frame(ctx.engine).main_command_buffer

    scissor := vk.Rect2D{
        offset = vk.Offset2D{ x = i32(rect.x), y = i32(rect.y) },
        extent = vk.Extent2D{ width = u32(rect.w), height = u32(rect.h) },
    }

    vk.CmdSetScissor(cmd, 0, 1, &scissor)
}

@(private="file")
ui_push_quad :: proc(
    draw_ctx: ^Ui_Draw_Context,
    x, y, w, h: f32,
    uv_min: Vec2,
    uv_max: Vec2,
    color: mu.Color,
    is_text: bool)
{
    if draw_ctx.vertex_count + 4 > i32(len(draw_ctx.vertices)) ||
       draw_ctx.index_count + 6 > i32(len(draw_ctx.indices)) {
        log.error("Not enough space in vertex or index buffer for UI quad")
        return
    }

    f := u32(1) if is_text else 0

    col := ui_convert_color(color)

    base_index := draw_ctx.vertex_count

    yy := -y
    hh := -h

    draw_ctx.vertices[draw_ctx.vertex_count + 0] = { position = { x, yy }, uvs = uv_min, color = col, flags = f }
    draw_ctx.vertices[draw_ctx.vertex_count + 1] = { position = { x + w, yy }, uvs = { uv_max.x, uv_min.y }, color = col, flags = f }
    draw_ctx.vertices[draw_ctx.vertex_count + 2] = { position = { x + w, yy + hh }, uvs = uv_max, color = col, flags = f }
    draw_ctx.vertices[draw_ctx.vertex_count + 3] = { position = { x, yy + hh }, uvs = { uv_min.x, uv_max.y }, color = col, flags = f }
    draw_ctx.vertex_count += 4

    draw_ctx.indices[draw_ctx.index_count + 0] = u32(base_index + 0)
    draw_ctx.indices[draw_ctx.index_count + 1] = u32(base_index + 3)
    draw_ctx.indices[draw_ctx.index_count + 2] = u32(base_index + 1)
    draw_ctx.indices[draw_ctx.index_count + 3] = u32(base_index + 1)
    draw_ctx.indices[draw_ctx.index_count + 4] = u32(base_index + 3)
    draw_ctx.indices[draw_ctx.index_count + 5] = u32(base_index + 2)

    draw_ctx.index_count += 6
}

