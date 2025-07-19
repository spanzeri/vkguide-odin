package vkguide

import "core:log"
import "core:os"
import "core:mem"

start :: proc() -> (ok: bool) {
    engine := VulkanEngine{}
    if !engine_init(&engine) {
        return false
    }
    defer engine_shutdown(&engine)
    engine_run(&engine)

    return true
}

main :: proc() {
    when ODIN_DEBUG {
        context.logger = log.create_console_logger(opt = { .Level, .Terminal_Color })
        defer log.destroy_console_logger(context.logger)

        track : mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        defer mem.tracking_allocator_destroy(&track)

        context.allocator = mem.tracking_allocator(&track)

        defer {
            if len(track.allocation_map) > 0 {
                log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
                for _, entry in track.allocation_map {
                    log.debugf("  | %v bytes @ %v", entry.size, entry.location)
                }
            }
            if len(track.bad_free_array) > 0 {
                log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
                for entry in track.bad_free_array {
                    log.debugf("  | %p @ %v", entry.memory, entry.location)
                }
            }
            assert(len(track.allocation_map) == 0, "Memory leak detected")
            assert(len(track.bad_free_array) == 0, "Incorrect memory frees detected")
        }
    }

    if !start() {
        os.exit(1)
    }
}

