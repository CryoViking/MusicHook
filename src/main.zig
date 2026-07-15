const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    // A pre-initialised general purpose allocator for temporary heap work
    const allocator = init.gpa;

    var arg_iterator = init.minimal.args.iterate();

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    _ = arg_iterator.skip(); // Skip the first argument since it's the binary
    while (arg_iterator.next()) |arg| {
        try list.append(allocator, arg);
    }

    _ = try cli.parse(list.items);

    std.debug.print("MusicHook is awake\n", .{});
}
