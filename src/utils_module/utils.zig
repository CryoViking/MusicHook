const std = @import("std");

pub fn runtime_socket_path(
    allocator: std.mem.Allocator,
    xdg_runtime_dir: ?[]const u8,
    temp_dir: ?[]const u8,
) ![]u8 {
    if (xdg_runtime_dir) |runtime_dir| {
        if (std.fs.path.isAbsolute(runtime_dir)) {
            return std.fs.path.join(allocator, &.{
                runtime_dir,
                "music_hook",
                "host.sock",
            });
        }
    }

    if (temp_dir) |runtime_dir| {
        if (std.fs.path.isAbsolute(runtime_dir)) {
            return std.fs.path.join(allocator, &.{
                runtime_dir,
                "music_hook",
                "host.sock",
            });
        }
    }

    return error.MissingRuntimeDirectory;
}
