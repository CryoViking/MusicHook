const std = @import("std");

pub const Command = enum {
    init,
    sync,
    list,
    play,
    add,
    remove,
    pause,
    @"resume",
    status,
};

pub const AddRequest = struct {
    alias: []const u8,
    url: []const u8,
};

pub const Request = union(Command) {
    init: void,
    sync: void,
    list: void,
    play: []const u8,
    add: AddRequest,
    remove: []const u8,
    pause: void,
    @"resume": void,
    status: void,
};

test "play request stores its target" {
    const request = Request{
        .play = "dusk",
    };

    switch (request) {
        .play => |target| try std.testing.expectEqualStrings(
            "dusk",
            target,
        ),
        else => unreachable,
    }
}

test "add request stores its alias and URL" {
    const request = Request{
        .add = .{
            .alias = "dusk",
            .url = "https://music.youtube.com/watch?v=example",
        },
    };

    switch (request) {
        .add => |target| {
            try std.testing.expectEqualStrings(
                "dusk",
                target.alias,
            );
            try std.testing.expectEqualStrings(
                "https://music.youtube.com/watch?v=example",
                target.url,
            );
        },
        else => unreachable,
    }
}

test "remove request stores its alias" {
    const request = Request{
        .remove = "dusk",
    };

    switch (request) {
        .remove => |alias| try std.testing.expectEqualStrings(
            "dusk",
            alias,
        ),
        else => unreachable,
    }
}

test "pause request has no payload" {
    const request = Request{
        .pause = {},
    };

    switch (request) {
        .pause => {},
        else => unreachable,
    }
}
