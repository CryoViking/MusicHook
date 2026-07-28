const std = @import("std");
const builtin = @import("builtin");

const CS_DARWIN_USER_TEMP_DIR: c_int = 65_537;
extern "c" fn confstr(name: c_int, buffer: ?[*]u8, length: usize) usize;

pub const ResolveRuntimeDirectoryError = error{
    MissingRuntimeDirectory,
    DarwinUserTempDirectoryUnavailable,
};

// Returns an allocator-owned absolute runtime directory.
// The caller must free the returned slice with the same allocator.
pub fn resolve_runtime_dir(allocator: std.mem.Allocator, xdg_runtime_dir: ?[]const u8, temp_dir: ?[]const u8) ![]u8 {
    if (builtin.os.tag == .macos) return darwin_user_temp_dir(allocator);
    if (xdg_runtime_dir) |runtime_dir| if (std.fs.path.isAbsolute(runtime_dir)) return allocator.dupe(u8, runtime_dir);
    if (temp_dir) |runtime_dir| if (std.fs.path.isAbsolute(runtime_dir)) return allocator.dupe(u8, runtime_dir);
    return error.MissingRuntimeDirectory;
}

// Uses confstr(_CS_DARWIN_USER_TEMP_DIR) to obtains macOS's per-user
// temporary directory, such as /var/folders/.../T/
fn darwin_user_temp_dir(allocator: std.mem.Allocator) ![]u8 {
    std.debug.assert(builtin.os.tag == .macos);

    // `confstr` first tells us how many bytes it needs, including the NUL.
    const required_length = confstr(CS_DARWIN_USER_TEMP_DIR, null, 0);
    if (required_length == 0) return error.DarwinUserTempDirectoryUnavailable;

    // This buffer must include space for C's terminating NUL.
    const raw_path = try allocator.alloc(u8, required_length);
    defer allocator.free(raw_path);

    const written_length = confstr(CS_DARWIN_USER_TEMP_DIR, raw_path.ptr, raw_path.len);
    if (written_length != required_length) return error.DarwinUserTempDirectoryUnavailable;

    const path = raw_path[0 .. required_length - 1];
    if (!std.fs.path.isAbsolute(path)) return error.DarwinUserTempDirectoryUnavailable;

    // `raw_path` is freed by the defer, so duplicate only the useful NUL-free Zig
    // slice for the caller to own.
    return allocator.dupe(u8, path);
}

test "macOS runtime directory ignores process environment candidates" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const resolved = try resolve_runtime_dir(
        std.testing.allocator,
        "/not/the-darwin-runtime-directory",
        "/also/not-the-darwin-runtime-directory",
    );
    defer std.testing.allocator.free(resolved);

    const expected = try darwin_user_temp_dir(std.testing.allocator);
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, resolved);
}

test "non-macOS runtime directory prefers XDG_RUNTIME_DIR" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const resolved = try resolve_runtime_dir(
        std.testing.allocator,
        "/run/user/1000",
        "/tmp/user",
    );
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings("/run/user/1000", resolved);
}

test "non-macOS runtime directory falls back to TMPDIR" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;

    const resolved = try resolve_runtime_dir(
        std.testing.allocator,
        null,
        "/tmp/user",
    );
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings("/tmp/user", resolved);
}
