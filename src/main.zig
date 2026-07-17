const std = @import("std");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");
const music_library = @import("music_library.zig");

const PlayTargetKind = union(enum) {
    alias: []const u8,
    direct_url: []const u8,
    unsupported_url: []const u8,
};

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

        try execute(
            init.io,
            init.gpa,
            path,
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
            cli.ParseError.MissingPlayTarget => {
                std.debug.print("No play target was given", .{});
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
            const play_target = request.play_target orelse
                return protocol.ProtocolError.MissingPlayTarget;
            switch (classify_play_target(play_target)) {
                .unsupported_url => |url| {
                    execute_handle_unsupported_url(url);
                },
                .direct_url => |url| {
                    execute_play_direct_url(url);
                },
                .alias => |alias| {
                    const library = try music_library.MusicLibrary.load(
                        io,
                        allocator,
                        data_path,
                    );
                    defer library.deinit(allocator);
                    execute_play_alias(library, alias);
                },
            }
        },
        else => stub(),
    }
}

fn stub() void {
    std.debug.print("Stubbed command, doesn't exist yet\n", .{});
}

fn execute_handle_unsupported_url(url: []const u8) void {
    std.debug.print("Does not supported given url: {s}\n", .{url});
}

fn execute_play_direct_url(url: []const u8) void {
    std.debug.print("Would play {s} here\n", .{url});
}

fn execute_play_alias(
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

fn is_youtube_domain(domain: []const u8) bool {
    const targets = [_][]const u8{
        "youtube.com",
        "music.youtube.com",
    };

    for (targets) |target| {
        if (std.mem.eql(u8, domain, target) or
            std.mem.endsWith(u8, domain, target) and
                domain[domain.len - target.len - 1] == '.')
            return true;
    }
    return false;
}

fn classify_play_target(play_target: []const u8) PlayTargetKind {
    const uri = std.Uri.parse(play_target) catch {
        return PlayTargetKind{ .alias = play_target };
    };

    if (std.mem.eql(u8, uri.scheme, "https")) {
        if (uri.host) |host| {
            const domain = host.percent_encoded;
            if (is_youtube_domain(domain))
                return PlayTargetKind{ .direct_url = play_target };
        }
    }
    return PlayTargetKind{ .unsupported_url = play_target };
}

// SECTION: Test Harness
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

test "classify_play_target recognises a YouTube URL" {
    const result = classify_play_target(
        "https://www.youtube.com/watch?v=example",
    );

    switch (result) {
        .direct_url => |url| try std.testing.expectEqualStrings(
            "https://www.youtube.com/watch?v=example",
            url,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "classify_play_target recognises a YouTube Music URL" {
    const result = classify_play_target(
        "https://music.youtube.com/watch?v=example",
    );

    switch (result) {
        .direct_url => |url| try std.testing.expectEqualStrings(
            "https://music.youtube.com/watch?v=example",
            url,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "classify_play_target recognises an Unsupported URL" {
    const result = classify_play_target(
        "https://www.notyoutube.com/watch?v=example",
    );

    switch (result) {
        .unsupported_url => |url| try std.testing.expectEqualStrings(
            "https://www.notyoutube.com/watch?v=example",
            url,
        ),
        else => return error.TestUnexpectedResult,
    }
}

test "classify_play_target recognises an alias" {
    const result = classify_play_target(
        "dusk",
    );

    switch (result) {
        .alias => |alias| try std.testing.expectEqualStrings(
            "dusk",
            alias,
        ),
        else => return error.TestUnexpectedResult,
    }
}
