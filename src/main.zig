const std = @import("std");
const w = @import("window.zig");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-protocol.h");
});

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const window: *w.window = try w.createWindow(allocator, 603, 402);
    defer allocator.destroy(window);

    while (!window.shouldClose) {
        window.pollEvents() catch {
            break;
        };
    }

    window.destroy();
}
