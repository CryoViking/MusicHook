const std = @import("std");
const target = @import("target.zig");

pub const MusicLibraryError = target.TargetError || error{
    DuplicateAlias,
};

pub const MusicLibrary = struct {
    targets: []const target.Target,

    pub fn validate(self: MusicLibrary) MusicLibraryError!void {
        for (self.targets) |entry| {
            try entry.validate();
        }

        for (self.targets, 0..) |target_i, i| {
            for (self.targets[i + 1 ..]) |target_j| {
                if (std.mem.eql(u8, target_i.alias, target_j.alias))
                    return MusicLibraryError.DuplicateAlias;
            }
        }
    }
};

test "empty target list is valid" {
    const test_music_lib = MusicLibrary{
        .targets = &[_]target.Target{},
    };
    try test_music_lib.validate();
}

test "valid library validates" {
    const test_music_lib = MusicLibrary{
        .targets = &[_]target.Target{
            .{
                .alias = "Some alias",
                .title = "Some title",
                .kind = .playlist,
                .source = .youtube,
                .url = "Some url",
            },
            .{
                .alias = "Some other alias",
                .title = "Some title",
                .kind = .playlist,
                .source = .youtube,
                .url = "Some url",
            },
        },
    };

    try test_music_lib.validate();
}

test "duplicate alias detected" {
    const test_music_lib = MusicLibrary{
        .targets = &[_]target.Target{
            .{
                .alias = "Some alias",
                .title = "Some title",
                .kind = .playlist,
                .source = .youtube,
                .url = "Some url",
            },
            .{
                .alias = "Some alias",
                .title = "Some title",
                .kind = .playlist,
                .source = .youtube,
                .url = "Some url",
            },
        },
    };

    try std.testing.expectError(
        MusicLibraryError.DuplicateAlias,
        test_music_lib.validate(),
    );
}

test "target error propagates through" {
    const test_music_lib = MusicLibrary{
        .targets = &[_]target.Target{
            .{
                .alias = "Another alias",
                .title = "Some title",
                .kind = .playlist,
                .source = .youtube,
                .url = "Some url",
            },
            .{
                .alias = "",
                .title = "Some title",
                .kind = .playlist,
                .source = .youtube,
                .url = "Some url",
            },
        },
    };

    try std.testing.expectError(
        MusicLibraryError.EmptyAlias,
        test_music_lib.validate(),
    );
}
