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
import sttb "vendor:stb/truetype"

Ui_Config :: struct {
    font_path: string,
    font_size: int,
}

Ui_Context :: struct {
    mu_context: ^mu.Context,
    font: Ui_Font,
}

Ui_Font :: struct {
    info:         sttb.fontinfo,
    chardata:     []sttb.packedchar,
    first_char:   i32,
    last_char:    i32,
    scale:        f32,
    baseline:     u16,
    line_height:  u16,
    font_size:    i32,
    texture_size: [2]i32,
    texture_data: []u8, // @TODO[SP]: Replace with a texture handle
}

ui_init :: proc(ui_config: Ui_Config) -> (ui_context: Ui_Context, ok: bool) {
    ui_context.mu_context = new(mu.Context, context.allocator)
    defer if !ok {
        free(ui_context.mu_context, context.allocator)
    }

    // ui_context.mu_context.text_width  = _text_get_width
    // ui_context.mu_context.text_height = _text_get_height
    //
    // if !_load_font(ui_config) {
    //     return ui_context, false
    // }
    //
    //
    // ui_context.mu_context.style.font  = &ui_context.font

    log.infof("UI initialized successfully with font: %s", ui_config.font_path)
    return ui_context, true
}

ui_shutdown :: proc(ui_context: ^Ui_Context) {
    free(ui_context.mu_context)
    ui_context.mu_context = nil
}

/*======================================

    Fonts

======================================*/

@(private="file")
_text_get_width :: proc(text: string) -> (width: int) {
    return 0
}

@(private="file")
_text_get_height :: proc(text: string) -> (height: int) {
    return 0
}

@(private="file")
Font_Load_Config :: struct {
    path: string,
    font_size: i32,
    image_size: [2]i32,
    allocator: ^runtime.Allocator,
}

@(private="file")
_create_font_atlas :: proc(fl_config: Font_Load_Config) -> (finfo: Ui_Font, ok: bool) {
    font_data: []byte
    font_data, ok = os.read_entire_file_from_filename(fl_config.path, context.temp_allocator)
    if !ok {
        log.errorf("Failed to read font file: %s", fl_config.path)
        return
    }

    font_info: sttb.fontinfo
    if !sttb.InitFont(&font_info, raw_data(font_data), i32(len(font_data))) {
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
    defer if !ok {
        delete_slice(pixels, context.allocator)
    }

    pc: sttb.pack_context
    res := sttb.PackBegin(&pc, raw_data(pixels), fl_config.image_size.x, fl_config.image_size.y, 0, 2, nil)
    if res != 0 {
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
        delete_slice(chardata, context.allocator)
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

    finfo = Ui_Font{
        info         = font_info,
        chardata     = chardata,
        first_char   = i32(first_char),
        last_char    = i32(last_char),
        scale        = scale,
        baseline     = baseline,
        line_height  = line_height,
        font_size    = fl_config.font_size,
        texture_size = fl_config.image_size,
        texture_data = pixels,
    }

    return finfo, true
}

