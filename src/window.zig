const std = @import("std");
const shm = @import("shm.zig");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-protocol.h");
});

pub const window = struct {
    width: i32,
    height: i32,
    display: *c.struct_wl_display,
    registry: *c.struct_wl_registry,
    compositor: ?*c.struct_wl_compositor = null,
    wl_shm: ?*c.struct_wl_shm = null,
    xdg_wm_base: ?*c.struct_xdg_wm_base = null,
    pool: ?*c.struct_wl_shm_pool = null,
    buffer: ?*c.wl_buffer = null,
    shouldClose: bool = false,

    pub fn destroy(self: *window) void {
        c.wl_buffer_destroy(self.buffer);
        c.wl_shm_pool_destroy(self.pool);
        c.wl_display_disconnect(self.display);
    }

    pub fn pollEvents(self: *window) void {
        while (c.wl_display_prepare_read(self.display) != 0) {
            _ = c.wl_display_dispatch_pending(self.display);
        }
        _ = c.wl_display_flush(self.display);

        _ = c.wl_display_read_events(self.display);
        _ = c.wl_display_dispatch_pending(self.display);
    }
};

pub fn createWindow(allocator: std.mem.Allocator, width: i32, height: i32) !*window {
    const state: *window = try allocator.create(window);
    state.width = width;
    state.height = height;

    state.display = c.wl_display_connect(null) orelse {
        std.debug.print("Failed to connect to Wayland display\n", .{});
        unreachable;
    };
    state.registry = c.wl_display_get_registry(state.display) orelse {
        std.debug.print("Failed to get Wayland registry\n", .{});
        unreachable;
    };

    const registryListener = c.struct_wl_registry_listener{
        .global = registry_handle_global,
        .global_remove = registry_handle_global_remove,
    };

    _ = c.wl_registry_add_listener(state.registry, &registryListener, state);

    if (c.wl_display_roundtrip(state.display) == -1) {
        std.debug.print("Failed initial roundtrip\n", .{});
        unreachable;
    }

    const surface = c.wl_compositor_create_surface(state.compositor);

    const windowSize = width * height * 4;
    const bufSize = windowSize * 2;

    const poolFd = try shm.get_shm_fd(bufSize);

    const mapFlags: std.posix.MAP = .{
        .TYPE = .SHARED,
    };
    const poolData = try std.posix.mmap(null, @intCast(bufSize), std.posix.PROT.READ | std.posix.PROT.WRITE, mapFlags, poolFd, 0);
    //@memset(poolData[0..@intCast(bufSize)], 0xFF);
    checker_pattern(poolData, @intCast(bufSize), @intCast(width * 4));

    state.pool = c.wl_shm_create_pool(state.wl_shm, @intCast(poolFd), windowSize);
    const buffer = c.wl_shm_pool_create_buffer(state.pool, 0, width, height, width * 4, c.WL_SHM_FORMAT_ARGB8888);
    state.buffer = buffer;

    const xdg_wm_base_listeners = c.struct_xdg_wm_base_listener{
        .ping = xdg_wm_base_ping,
    };
    _ = c.xdg_wm_base_add_listener(state.xdg_wm_base, &xdg_wm_base_listeners, state);

    const xdg_surface = c.xdg_wm_base_get_xdg_surface(state.xdg_wm_base, surface) orelse unreachable;
    const surface_listener = c.struct_xdg_surface_listener{
        .configure = xdg_surface_configure,
    };
    _ = c.xdg_surface_add_listener(xdg_surface, &surface_listener, state);

    const xdg_toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse unreachable;
    const toplevel_listener = c.struct_xdg_toplevel_listener{
        .close = toplevel_close,
        .configure = toplevel_configure,
    };

    _ = c.xdg_toplevel_add_listener(xdg_toplevel, &toplevel_listener, state);
    c.xdg_toplevel_set_title(xdg_toplevel, "wl-test");
    c.xdg_surface_set_window_geometry(xdg_surface, 0, 0, width, height);

    c.wl_surface_attach(surface, buffer, 0, 0);
    c.wl_surface_damage(surface, 0, 0, width, height);
    c.wl_surface_commit(surface);

    return state;
}

fn checker_pattern(region: []u8, size: usize, stride: usize) void {
    for (0..(size / stride)) |row| {
        for (0..(stride / 4)) |column| {
            const checkerSize: usize = 50;
            const rowColor = (row / checkerSize) % 2;
            const pixelColor: u8 = @truncate((column / checkerSize + rowColor) % 2);

            region[row * stride + column * 4 + 0] = pixelColor * 0xFF;
            region[row * stride + column * 4 + 1] = pixelColor * 0xFF;
            region[row * stride + column * 4 + 2] = pixelColor * 0xFF;
            region[row * stride + column * 4 + 3] = 0xFF; // alpha
        }
    }
}

fn registry_handle_global(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const state: *window = @ptrCast(@alignCast(data));
    _ = version;

    if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_compositor_interface.name))) {
        const compositor = c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4) orelse unreachable;
        state.compositor = @ptrCast(compositor);
    } else if (std.mem.eql(u8, std.mem.span(interface), std.mem.span(c.wl_shm_interface.name))) {
        const wl_shm = c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1) orelse unreachable;
        state.wl_shm = @ptrCast(wl_shm);
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
    const state: *window = @ptrCast(@alignCast(data));
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

fn xdg_surface_configure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const state: *window = @ptrCast(@alignCast(data));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    _ = state;
}
