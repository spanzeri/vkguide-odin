package vkguide

import "base:runtime"
import intr "base:intrinsics"
import "core:log"
import "core:math"

import vk "vendor:vulkan"

@(require_results)
vk_check :: #force_inline proc(
    res: vk.Result,
    message:= "Detected vulkan error",
    loc := #caller_location,
) -> bool {
    if intr.expect(res, vk.Result.SUCCESS) == .SUCCESS {
        return true
    }

    log.errorf("[Vulkan Error] %s: %v", message, res)
    runtime.print_caller_location(loc)
    return false
}

Vec2i :: [2]i32
Vec2u :: [2]u32
Vec2f :: [2]f32
Vec2  :: Vec2f
Vec3i :: [3]i32
Vec3u :: [3]u32
Vec3f :: [3]f32
Vec3  :: Vec3f
Vec4i :: [4]i32
Vec4u :: [4]u32
Vec4f :: [4]f32
Vec4  :: Vec4f
Mat4  :: matrix[4, 4]f32

vec_dot :: proc(a, b: [$N]$T) -> T where intr.type_is_numeric(T) {
    res := $T(0)
    for i < len(a) {
        res = a[i] * b[i]
    }
    return res
}

@(require_results)
matrix4_infinite_perspective_reverse_z_f32 :: proc "contextless" (
    fovy, aspect, near: f32,
) -> (m: Mat4) #no_bounds_check {
    f := 1.0 / math.tan(fovy * 0.5)
    m[0, 0] =  f / aspect
    m[1, 1] =  f
    m[3, 2] = -1.0
    m[2, 3] = near

    return
}

