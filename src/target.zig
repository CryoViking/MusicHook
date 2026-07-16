const std = @import("std");

pub const TargetError = error{
    EmptyAlias,
    EmptyTitle,
    EmptyURL,
};

pub const TargetKind = enum {
    playlist,
    track,
};

pub const TargetSource = enum {
    ytmusic,
    youtube,
};

pub const Target = struct {
    alias: []const u8,
    title: []const u8,
    kind: TargetKind,
    source: TargetSource,
    url: []const u8,

    pub fn validate(self: Target) TargetError!void {
        if (self.alias.len == 0) return TargetError.EmptyAlias;
        if (self.title.len == 0) return TargetError.EmptyTitle;
        if (self.url.len == 0) return TargetError.EmptyURL;
    }
};

test "valid target validates" {
    const target = Target{
        .alias = "Some alias",
        .title = "Some title",
        .kind = .playlist,
        .source = .youtube,
        .url = "Some url",
    };

    try target.validate();
}

test "missing alias" {
    const target = Target{
        .alias = "",
        .title = "Some title",
        .kind = .playlist,
        .source = .youtube,
        .url = "Some url",
    };

    try std.testing.expectError(
        TargetError.EmptyAlias,
        target.validate(),
    );
}

test "missing title" {
    const target = Target{
        .alias = "Some alias",
        .title = "",
        .kind = .playlist,
        .source = .youtube,
        .url = "Some url",
    };

    try std.testing.expectError(
        TargetError.EmptyTitle,
        target.validate(),
    );
}

test "missing url" {
    const target = Target{
        .alias = "Some alias",
        .title = "Some title",
        .kind = .playlist,
        .source = .youtube,
        .url = "",
    };

    try std.testing.expectError(
        TargetError.EmptyURL,
        target.validate(),
    );
}
