const std = @import("std");
const protocol = @import("protocol.zig");

// Examples:
//
// ["play", "dusk"]
//   → Request{ .play = "dusk" }
//
// ["add", "dusk", "https://music.youtube.com/watch?v=example"]
//   → Request{ .add = .{ .alias = "dusk", .url = "..." } }
//
// ["remove", "dusk"]
//   → Request{ .remove = "dusk" }

pub const ParseError = error{
    MissingCommand,
    UnknownCommand,
    MissingPlayTarget,
    MissingAddAlias,
    MissingAddUrl,
    MissingRemoveAlias,
    UnexpectedArgument,
};

pub fn parse(args: []const []const u8) ParseError!protocol.Request {
    if (args.len == 0) return error.MissingCommand;

    const command = std.meta.stringToEnum(
        protocol.Command,
        args[0],
    ) orelse return error.UnknownCommand;

    return switch (command) {
        .play => parse_play(args),
        .add => parse_add(args),
        .remove => parse_remove(args),
        .init => parse_without_arguments(
            .{ .init = {} },
            args,
        ),
        .sync => parse_without_arguments(
            .{ .sync = {} },
            args,
        ),
        .list => parse_without_arguments(
            .{ .list = {} },
            args,
        ),
        .pause => parse_without_arguments(
            .{ .pause = {} },
            args,
        ),
        .@"resume" => parse_without_arguments(
            .{ .@"resume" = {} },
            args,
        ),
        .status => parse_without_arguments(
            .{ .status = {} },
            args,
        ),
    };
}

fn parse_play(args: []const []const u8) ParseError!protocol.Request {
    std.debug.assert(args.len >= 1);

    if (args.len == 1) return error.MissingPlayTarget;
    if (args.len > 2) return error.UnexpectedArgument;

    return .{ .play = args[1] };
}

fn parse_add(args: []const []const u8) ParseError!protocol.Request {
    std.debug.assert(args.len >= 1);

    if (args.len == 1) return error.MissingAddAlias;
    if (args.len == 2) return error.MissingAddUrl;
    if (args.len > 3) return error.UnexpectedArgument;

    return .{
        .add = .{
            .alias = args[1],
            .url = args[2],
        },
    };
}

fn parse_remove(args: []const []const u8) ParseError!protocol.Request {
    std.debug.assert(args.len >= 1);

    if (args.len == 1) return error.MissingRemoveAlias;
    if (args.len > 2) return error.UnexpectedArgument;

    return .{ .remove = args[1] };
}

fn parse_without_arguments(
    request: protocol.Request,
    args: []const []const u8,
) ParseError!protocol.Request {
    std.debug.assert(args.len >= 1);

    if (args.len > 1) return error.UnexpectedArgument;

    return request;
}

// SECTION: CLI tests
fn expect_command(
    expected: protocol.Command,
    request: protocol.Request,
) !void {
    try std.testing.expectEqual(
        expected,
        std.meta.activeTag(request),
    );
}

test "fails with no command" {
    const args = [_][]const u8{};

    try std.testing.expectError(
        ParseError.MissingCommand,
        parse(&args),
    );
}

test "fails with unknown command" {
    const args = [_][]const u8{"unknown"};

    try std.testing.expectError(
        ParseError.UnknownCommand,
        parse(&args),
    );
}

test "parses play with a target" {
    const args = [_][]const u8{ "play", "dusk" };

    const request = try parse(&args);

    try expect_command(.play, request);

    switch (request) {
        .play => |target| try std.testing.expectEqualStrings(
            "dusk",
            target,
        ),
        else => unreachable,
    }
}

test "play fails with no target" {
    const args = [_][]const u8{"play"};

    try std.testing.expectError(
        ParseError.MissingPlayTarget,
        parse(&args),
    );
}

test "play fails with extra arguments" {
    const args = [_][]const u8{
        "play",
        "dusk",
        "extra",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "parses add with an alias and URL" {
    const args = [_][]const u8{
        "add",
        "dusk",
        "https://music.youtube.com/watch?v=example",
    };

    const request = try parse(&args);

    try expect_command(.add, request);

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

test "add fails with no alias" {
    const args = [_][]const u8{"add"};

    try std.testing.expectError(
        ParseError.MissingAddAlias,
        parse(&args),
    );
}

test "add fails with no URL" {
    const args = [_][]const u8{
        "add",
        "dusk",
    };

    try std.testing.expectError(
        ParseError.MissingAddUrl,
        parse(&args),
    );
}

test "add fails with extra arguments" {
    const args = [_][]const u8{
        "add",
        "dusk",
        "https://music.youtube.com/watch?v=example",
        "extra",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "parses remove with an alias" {
    const args = [_][]const u8{
        "remove",
        "dusk",
    };

    const request = try parse(&args);

    try expect_command(.remove, request);

    switch (request) {
        .remove => |alias| try std.testing.expectEqualStrings(
            "dusk",
            alias,
        ),
        else => unreachable,
    }
}

test "remove fails with no alias" {
    const args = [_][]const u8{"remove"};

    try std.testing.expectError(
        ParseError.MissingRemoveAlias,
        parse(&args),
    );
}

test "remove fails with extra arguments" {
    const args = [_][]const u8{
        "remove",
        "dusk",
        "extra",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "parses commands without arguments" {
    const cases = [_]struct {
        argument: []const u8,
        command: protocol.Command,
    }{
        .{ .argument = "init", .command = .init },
        .{ .argument = "sync", .command = .sync },
        .{ .argument = "list", .command = .list },
        .{ .argument = "pause", .command = .pause },
        .{ .argument = "resume", .command = .@"resume" },
        .{ .argument = "status", .command = .status },
    };

    for (cases) |case| {
        const args = [_][]const u8{case.argument};
        const request = try parse(&args);

        try expect_command(case.command, request);
    }
}

test "commands without arguments reject an extra argument" {
    const cases = [_][]const u8{
        "init",
        "sync",
        "list",
        "pause",
        "resume",
        "status",
    };

    for (cases) |command| {
        const args = [_][]const u8{
            command,
            "extra",
        };

        try std.testing.expectError(
            ParseError.UnexpectedArgument,
            parse(&args),
        );
    }
}
