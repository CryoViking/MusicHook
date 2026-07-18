const std = @import("std");

pub const ProtocolError = error{
    MissingPlayTarget,
    UnexpectedPlayTarget,
};

pub const Command = enum {
    init,
    sync,
    list,
    play,
    pause,
    @"resume",
    status,
};

pub const Request = struct {
    command: Command,
    play_target: ?[]const u8 = null,

    pub fn validate(self: Request) ProtocolError!void {
        switch (self.command) {
            .play => if (self.play_target == null) return error.MissingPlayTarget,
            else => if (self.play_target != null) return error.UnexpectedPlayTarget,
        }
    }
};

test "play requires an play_target" {
    const request = Request{ .command = .play };
    try std.testing.expectError(
        error.MissingPlayTarget,
        request.validate(),
    );
}

test "pause does not accept an play_target" {
    const request = Request{
        .command = .pause,
        .play_target = "dusk",
    };
    try std.testing.expectError(
        error.UnexpectedPlayTarget,
        request.validate(),
    );
}

test "play accepts an play_target" {
    const request = Request{
        .command = .play,
        .play_target = "dusk",
    };
    try request.validate();
}
