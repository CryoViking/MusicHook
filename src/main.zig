const std = @import("std");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");
const music_library = @import("music_library.zig");

pub fn main(init: std.process.Init) !u8 {
    // A pre-initialised general purpose allocator for temporary heap work
    const allocator = init.gpa;

    var arg_iterator = init.minimal.args.iterate();

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);

    _ = arg_iterator.skip(); // Skip the first argument since it's the binary
    while (arg_iterator.next()) |arg| {
        try list.append(allocator, arg);
    }

    if (cli.parse(list.items)) |request| {
        const home = init.environ_map.get("HOME") orelse return error.MissingHome;
        const path = try library_path(allocator, home);
        defer allocator.free(path);

        const lib_path = "~/.config/music_hook/music_library.zon";
        try execute(
            init.io,
            init.gpa,
            lib_path,
            request,
        );

        return 0;
    } else |err| {
        switch (err) {
            cli.ParseError.UnknownCommand => {
                // TODO: Should get the unknown command and print it somehow
                std.debug.print("Unknown command given\n", .{});
            },
            cli.ParseError.MissingCommand => {
                // TODO: Should print help menu maybe?
                std.debug.print("Missing a command argument\n", .{});
            },
            cli.ParseError.UnexpectedArgument => {
                // TODO: Should get number of given arguments
                // AND number of expected arguments and show something
                // along those lines
                std.debug.print("Unexpected argument given\n", .{});
            },
            cli.ParseError.MissingAlias => {
                std.debug.print("No playlist alias given\n", .{});
            },
        }
        return 1; // return a non-zero exit code
    }
}

fn execute(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_path: []const u8,
    request: protocol.Request,
) !void {
    switch (request.command) {
        .play => {
            const library = try music_library.MusicLibrary.load(
                io,
                allocator,
                data_path,
            );
            defer library.deinit(allocator);
            execute_play(library, request.alias.?);
        },
        else => stub(),
    }
}

fn stub() void {
    std.debug.print("Stubbed command, doesn't exist yet\n", .{});
}

fn execute_play(
    library: music_library.MusicLibrary,
    alias: []const u8,
) void {
    const request_target = library.find(alias);
    if (request_target) |item| {
        std.debug.print(
            "Target found: alias - {s} | title - {s}",
            .{
                item.alias,
                item.title,
            },
        );
    } else {
        std.debug.print(
            "Could not find Target with that alias\n",
            .{},
        );
    }
    return;
}

fn library_path(
    allocator: std.mem.Allocator,
    home: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fs.path.join(allocator, &.{
        home,
        ".config",
        "music_hook",
        "music_library.zon",
    });
}

test "library_path builds the music library location" {
    const path = try library_path(
        std.testing.allocator,
        "/home/shiori",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(
        "/home/shiori/.config/music_hook/music_library.zon",
        path,
    );
}
