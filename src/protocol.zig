const std = @import("std");

pub const ProtocolError = error{
    MissingAlias,
    UnexpectedAlias,
};

pub const Command = enum {
    sync,
    list,
    play,
    pause,
    @"resume",
    status,
};

pub const Request = struct {
    command: Command,
    alias: ?[]const u8 = null,

    pub fn validate(self: Request) ProtocolError!void {
        switch (self.command) {
            .play => if (self.alias == null) return error.MissingAlias,
            else => if (self.alias != null) return error.UnexpectedAlias,
        }
    }
};

test "play requires an alias" {
    const request = Request{ .command = .play };
    try std.testing.expectError(
        error.MissingAlias,
        request.validate(),
    );
}

test "pause does not accept an alias" {
    const request = Request{
        .command = .pause,
        .alias = "dusk",
    };
    try std.testing.expectError(
        error.UnexpectedAlias,
        request.validate(),
    );
}

test "play accepts an alias" {
    const request = Request{
        .command = .play,
        .alias = "dusk",
    };
    try request.validate();
}
