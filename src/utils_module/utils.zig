const std = @import("std");

pub fn runtime_socket_path(
    allocator: std.mem.Allocator,
    runtime_dir: []const u8,
) ![]u8 {
    if (!std.fs.path.isAbsolute(runtime_dir)) return error.RelativeRuntimeDirectory;
    return std.fs.path.join(allocator, &.{ runtime_dir, "music_hook", "host.sock" });
}
