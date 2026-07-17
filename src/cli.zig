const std = @import("std");
const protocol = @import("protocol.zig");

// The job of this parser is to essentially do the following:
// ["play", "dusk"]  →  Request{ .command = .play, .alias = "dusk" }
// ["pause"]         →  Request{ .command = .pause }
// ["play"]          →  error.MissingPlayTarget
// ["dance"]         →  error.UnknownCommand

pub const ParseError = error{
    MissingCommand,
    UnknownCommand,
    MissingPlayTarget,
    UnexpectedArgument,
};

pub fn parse(args: []const []const u8) ParseError!protocol.Request {
    if (args.len == 0) return error.MissingCommand;

    return switch (std.meta.stringToEnum(
        protocol.Command,
        args[0],
    ) orelse return error.UnknownCommand) {
        .play => parsePlay(args),
        else => |command| parseWithoutAlias(
            command,
            args,
        ),
    };
}

fn parsePlay(args: []const []const u8) ParseError!protocol.Request {
    std.debug.assert(args.len >= 1);

    if (args.len == 1) return error.MissingPlayTarget;
    if (args.len > 2) return error.UnexpectedArgument;

    return .{
        .command = .play,
        .play_target = args[1],
    };
}

fn parseWithoutAlias(
    command: protocol.Command,
    args: []const []const u8,
) ParseError!protocol.Request {
    std.debug.assert(args.len >= 1);

    if (args.len > 1) return error.UnexpectedArgument;

    return .{ .command = command };
}

// SECTION: CLI tests
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

test "play does accept an alias" {
    const args = [_][]const u8{ "play", "dusk" };

    const request = try parse(&args);

    try std.testing.expectEqual(
        protocol.Command.play,
        request.command,
    );
    try std.testing.expect(request.play_target != null);
    try std.testing.expectEqual(
        request.play_target,
        "dusk",
    );
}

test "play fails on no alias" {
    const args = [_][]const u8{"play"};

    try std.testing.expectError(
        ParseError.MissingPlayTarget,
        parse(&args),
    );
}

test "play fails on extra arguments" {
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

test "pause does not accept an alias" {
    const args = [_][]const u8{"pause"};

    const request = try parse(&args);

    try std.testing.expectEqual(
        protocol.Command.pause,
        request.command,
    );
    try std.testing.expect(request.play_target == null);
}

test "pause fails on alias" {
    const args = [_][]const u8{
        "pause",
        "dusk",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "sync does not accept an alias" {
    const args = [_][]const u8{"sync"};

    const request = try parse(&args);

    try std.testing.expectEqual(
        protocol.Command.sync,
        request.command,
    );
    try std.testing.expect(request.play_target == null);
}

test "sync fails on alias" {
    const args = [_][]const u8{
        "sync",
        "dusk",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "list does not accept an alias" {
    const args = [_][]const u8{"list"};

    const request = try parse(&args);

    try std.testing.expectEqual(
        protocol.Command.list,
        request.command,
    );
    try std.testing.expect(request.play_target == null);
}

test "list fails on alias" {
    const args = [_][]const u8{
        "list",
        "dusk",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "status does not accept an alias" {
    const args = [_][]const u8{"status"};

    const request = try parse(&args);

    try std.testing.expectEqual(
        protocol.Command.status,
        request.command,
    );
    try std.testing.expect(request.play_target == null);
}

test "status fails on alias" {
    const args = [_][]const u8{
        "status",
        "dusk",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "resume does not accept an alias" {
    const args = [_][]const u8{"resume"};

    const request = try parse(&args);

    try std.testing.expectEqual(
        protocol.Command.@"resume",
        request.command,
    );
    try std.testing.expect(request.play_target == null);
}

test "resume fails on alias" {
    const args = [_][]const u8{
        "resume",
        "dusk",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}

test "init does not accept an alias" {
    const args = [_][]const u8{"init"};

    const request = try parse(&args);

    try std.testing.expectEqual(
        protocol.Command.init,
        request.command,
    );
    try std.testing.expect(request.play_target == null);
}

test "init fails on alias" {
    const args = [_][]const u8{
        "init",
        "dusk",
    };

    try std.testing.expectError(
        ParseError.UnexpectedArgument,
        parse(&args),
    );
}
