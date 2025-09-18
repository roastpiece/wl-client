const std = @import("std");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-protocol.h");
});

const app_state = struct {
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    xdg_wm_base: ?*c.struct_xdg_wm_base = null,
    pool: ?*c.struct_wl_shm_pool = null,
    shouldClose: bool = false,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const display = c.wl_display_connect(null);
    const registry = c.wl_display_get_registry(display);

    const registryListener = c.struct_wl_registry_listener{
        .global = registry_handle_global,
        .global_remove = registry_handle_global_remove,
    };

    const state: *app_state = try allocator.create(app_state);

    _ = c.wl_registry_add_listener(registry, &registryListener, state);

    if (c.wl_display_roundtrip(display) == -1) {
        std.debug.print("Failed initial roundtrip\n", .{});
        unreachable;
    }

    const compositor = state.compositor orelse unreachable;
    const shm = state.shm orelse unreachable;

    const surface = c.wl_compositor_create_surface(compositor);

    var random = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const bufSize = 256 * 256 * 4 * 2;
    const poolFd = try create_shm_fd(random.random(), bufSize);

    const mapFlags: std.posix.MAP = .{
        .TYPE = .SHARED,
    };
    const poolData = try std.posix.mmap(null, bufSize, std.posix.PROT.READ | std.posix.PROT.WRITE, mapFlags, poolFd, 0);
    @memset(poolData[0..bufSize], 0xFF);

    state.pool = c.wl_shm_create_pool(shm, @intCast(poolFd), 256 * 256 * 4);
    const buffer = c.wl_shm_pool_create_buffer(state.pool, 0, 256, 256, 256 * 4, c.WL_SHM_FORMAT_ARGB8888);

    const xdg_shell_surface = c.xdg_wm_base_get_xdg_surface(state.xdg_wm_base, surface) orelse unreachable;

    const xdg_wm_base_listeners = c.struct_xdg_wm_base_listener{
        .ping = xdg_wm_base_ping,
    };
    _ = c.xdg_wm_base_add_listener(state.xdg_wm_base, &xdg_wm_base_listeners, state);

    const xdg_toplevel = c.xdg_surface_get_toplevel(xdg_shell_surface) orelse unreachable;
    const toplevel_listener = c.struct_xdg_toplevel_listener{
        .close = toplevel_close,
        .configure = toplevel_configure,
    };

    _ = c.xdg_toplevel_add_listener(xdg_toplevel, &toplevel_listener, state);
    c.xdg_toplevel_set_title(xdg_toplevel, "wl-test");
    c.xdg_surface_set_window_geometry(xdg_shell_surface, 0, 0, 256, 256);

    c.wl_surface_attach(surface, buffer, 0, 0);
    c.wl_surface_damage(surface, 0, 0, 256, 256);
    c.wl_surface_commit(surface);

    while (true) {
        while (c.wl_display_prepare_read(display) != 0) {
            _ = c.wl_display_dispatch_pending(display);
        }
        _ = c.wl_display_flush(display);

        _ = c.wl_display_read_events(display);
        _ = c.wl_display_dispatch_pending(display);

        if (state.shouldClose) break;
    }

    c.wl_buffer_destroy(buffer);
    c.wl_shm_pool_destroy(state.pool);
    c.wl_display_disconnect(display);
}

fn create_shm_fd(random: std.Random, size: i64) error{NoSpaceLeft}!c_int {
    var name_buf: [32]u8 = undefined;
    const randomNumber = random.intRangeAtMost(u32, 100_000, 999_999);
    const name = try std.fmt.bufPrint(&name_buf, "/wl_shm-{d}", .{randomNumber});

    const shmFlags: std.os.linux.O = .{
        .CREAT = true,
        .EXCL = true,
        .ACCMODE = std.posix.ACCMODE.RDWR,
    };
    const fd = std.c.shm_open(@ptrCast(name), @bitCast(shmFlags), 0o600);
    if (fd == -1) {
        std.debug.print("shm_open failed\n", .{});
        unreachable;
    }
    if (std.c.ftruncate(fd, size) == -1) {
        std.debug.print("ftruncate failed\n", .{});
        unreachable;
    }
    return fd;
}

fn registry_handle_global(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state: *app_state = @ptrCast(@alignCast(data));
    _ = version;

    if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_compositor_interface.name))) {
        const compositor = c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4) orelse unreachable;
        state.compositor = @ptrCast(compositor);
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_shm_interface.name))) {
        const shm = c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1) orelse unreachable;
        state.shm = @ptrCast(shm);
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.xdg_wm_base_interface.name))) {
        const xdg_wm_base = c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1) orelse unreachable;
        state.xdg_wm_base = @ptrCast(xdg_wm_base);
    }
}

fn registry_handle_global_remove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    // no-op
    _ = data;
    _ = registry;
    _ = name;
}

fn xdg_wm_base_ping(data: ?*anyopaque, xdg_wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(xdg_wm_base, serial);
}

fn toplevel_close(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel) callconv(.c) void {
    const state: *app_state = @ptrCast(@alignCast(data));
    state.shouldClose = true;
    _ = toplevel;
}

fn toplevel_configure(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel, width: i32, height: i32, states: ?*c.struct_wl_array) callconv(.c) void {
    // no-op
    _ = data;
    _ = toplevel;
    _ = width;
    _ = height;
    _ = states;
}
