const std = @import("std");

pub fn get_shm_fd(size: i64) error{NoSpaceLeft}!c_int {
    var name_buf: [32]u8 = undefined;
    var fd: c_int = -1;
    const random = random: {
        const prng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
        break :random std.Random.Xoshiro256.random(@constCast(&prng));
    };

    for (0..100) |_| {
        const randomNumber = random.intRangeAtMost(u32, 100_000, 999_999);
        const name = try std.fmt.bufPrint(&name_buf, "/wl_shm-{d}", .{randomNumber});

        const shmFlags: std.os.linux.O = .{
            .CREAT = true,
            .EXCL = true,
            .ACCMODE = std.posix.ACCMODE.RDWR,
        };
        fd = std.c.shm_open(@ptrCast(name), @bitCast(shmFlags), 0o600);

        if (fd == -1) {
            std.debug.print("shm_open failed\n", .{});
            continue;
        }
        if (std.c.ftruncate(fd, size) == -1) {
            std.debug.print("ftruncate failed\n", .{});
            unreachable;
        }
        break;
    }
    return fd;
}
