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

    pub fn load(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) !MusicLibrary {
        const contents = try dir.readFileAllocOptions(
            io,
            path,
            allocator,
            .limited(1024 * 1024),
            .of(u8),
            0,
        );
        defer allocator.free(contents);

        const library = try std.zon.parse.fromSliceAlloc(
            MusicLibrary,
            allocator,
            contents,
            null,
            .{},
        );
        // not ordinary defer because ownership changes on success:
        // - If parsing success but library.validate() fails, errdefer frees the
        // partially acquired library before returning that error.
        // - If validation succeeds and you return library, errdefer does not run.
        // Ownership transfers to the caller.
        // - The caller later invokes library.deinit(allocator)
        errdefer std.zon.parse.free(allocator, library);

        try library.validate();
        return library;
    }

    pub fn deinit(
        self: MusicLibrary,
        allocator: std.mem.Allocator,
    ) void {
        std.zon.parse.free(allocator, self);
    }

    pub fn write_new(
        self: MusicLibrary,
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        try self.validate();

        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();

        var serializer = std.zon.Serializer{
            .writer = &output.writer,
        };

        var zon_library = try serializer.beginStruct(.{
            .whitespace_style = .{ .wrap = true },
        });

        var zon_targets = try zon_library.beginTupleField(
            "targets",
            .{ .whitespace_style = .{ .wrap = true } },
        );

        for (self.targets) |entry| {
            var zon_target = try zon_targets.beginStructField(
                .{ .whitespace_style = .{ .wrap = true } },
            );

            try zon_target.field("alias", entry.alias, .{});
            try zon_target.field("title", entry.title, .{});
            try zon_target.field("kind", entry.kind, .{});
            try zon_target.field("source", entry.source, .{});
            try zon_target.field("url", entry.url, .{});

            try zon_target.end();
        }

        try zon_targets.end();
        try zon_library.end();

        try output.writer.writeByte('\n');

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.writer.buffered(),
            .flags = .{
                .exclusive = true,
            },
        });
    }

    // TODO: Should have just 1 write method that takes in a bool for "write_new"
    pub fn write(
        self: MusicLibrary,
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) !void {
        try self.validate();

        var output = std.Io.Writer.Allocating.init(allocator);
        defer output.deinit();

        var serializer = std.zon.Serializer{
            .writer = &output.writer,
        };

        var zon_library = try serializer.beginStruct(.{
            .whitespace_style = .{ .wrap = true },
        });

        var zon_targets = try zon_library.beginTupleField(
            "targets",
            .{ .whitespace_style = .{ .wrap = true } },
        );

        for (self.targets) |entry| {
            var zon_target = try zon_targets.beginStructField(
                .{ .whitespace_style = .{ .wrap = true } },
            );

            try zon_target.field("alias", entry.alias, .{});
            try zon_target.field("title", entry.title, .{});
            try zon_target.field("kind", entry.kind, .{});
            try zon_target.field("source", entry.source, .{});
            try zon_target.field("url", entry.url, .{});

            try zon_target.end();
        }

        try zon_targets.end();
        try zon_library.end();

        try output.writer.writeByte('\n');

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.writer.buffered(),
            .flags = .{
                .exclusive = false,
            },
        });
    }

    pub fn find(
        self: MusicLibrary,
        alias: []const u8,
    ) ?*const target.Target {
        for (self.targets) |*item| if (std.mem.eql(u8, item.alias, alias)) return item;
        return null;
    }

    pub fn add(
        self: MusicLibrary,
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
        new_target: target.Target,
    ) !void {
        if (self.find(new_target.alias) != null) return MusicLibraryError.DuplicateAlias;

        var targets: std.ArrayList(target.Target) = .empty;
        defer targets.deinit(allocator);

        try targets.appendSlice(allocator, self.targets);
        try targets.append(allocator, new_target);

        const updated_library = MusicLibrary{
            .targets = targets.items,
        };
        try updated_library.write(io, allocator, dir, path);
    }

    pub fn remove(
        self: MusicLibrary,
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
        alias: []const u8,
    ) !bool {
        if (self.find(alias) == null) return false;

        var targets: std.ArrayList(target.Target) = .empty;
        defer targets.deinit(allocator);

        for (self.targets) |entry| {
            if (!std.mem.eql(u8, entry.alias, alias))
                try targets.append(allocator, entry);
        }

        const updated_library = MusicLibrary{
            .targets = targets.items,
        };
        try updated_library.write(io, allocator, dir, path);
        return true;
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

test "reads valid library fixture" {
    const library = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        "testdata/valid-library.zon",
    );
    defer library.deinit(std.testing.allocator);

    try std.testing.expect(library.targets.len == 2);
    try std.testing.expectEqualStrings(
        "dusk",
        library.targets[0].alias,
    );
    try std.testing.expectEqual(
        .playlist,
        library.targets[0].kind,
    );
}

test "rejects duplicated aliases in a fixture" {
    try std.testing.expectError(
        MusicLibraryError.DuplicateAlias,
        MusicLibrary.load(
            std.testing.io,
            std.testing.allocator,
            std.Io.Dir.cwd(),
            "testdata/duplicate-alias.zon",
        ),
    );
    // NOTE: no defer because load returns no library on error;
    // its errdefer performs cleanup.
}

test "finds alias in test fixture" {
    const library = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        "testdata/valid-library.zon",
    );
    defer library.deinit(std.testing.allocator);

    const music_target = library.find("dusk");
    try std.testing.expect(music_target != null);
    try std.testing.expectEqualStrings(
        "Dusk Focus",
        // NOTE: the .? unwraps the optional `music_target`
        music_target.?.title,
    );
}

test "returns null on non existent alias" {
    const library = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        "testdata/valid-library.zon",
    );
    defer library.deinit(std.testing.allocator);

    const music_target = library.find("dawn");
    try std.testing.expect(music_target == null);
}

test "writes a new library that can be loaded" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const expected = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
        },
    };

    try expected.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const actual = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer actual.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "dusk",
        actual.targets[0].alias,
    );
}

test "does not overwrite an existing library" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const expected = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
        },
    };

    try expected.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    try std.testing.expectError(
        error.PathAlreadyExists,
        expected.write_new(
            std.testing.io,
            std.testing.allocator,
            temp_dir.dir,
            "music_library.zon",
        ),
    );
}

test "write overwrites an existing library" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const initial = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
        },
    };

    try initial.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const expected = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
            .{
                .alias = "dawn",
                .title = "Dawn Focus",
                .kind = .track,
                .source = .youtube,
                .url = "https://www.youtube.com/watch?v=example",
            },
        },
    };

    try expected.write(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const actual = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer actual.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), actual.targets.len);
    try std.testing.expectEqualStrings("dawn", actual.targets[1].alias);
    try std.testing.expectEqualStrings(
        "Dawn Focus",
        actual.targets[1].title,
    );
}

test "adds a target to an existing library" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const initial = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
        },
    };

    try initial.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const library = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer library.deinit(std.testing.allocator);

    try library.add(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
        .{
            .alias = "dawn",
            .title = "Nightcore 🛡️ Focus Mix",
            .kind = .track,
            .source = .youtube,
            .url = "https://www.youtube.com/watch?v=example",
        },
    );

    const updated = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer updated.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), updated.targets.len);
    try std.testing.expectEqualStrings("dawn", updated.targets[1].alias);
    try std.testing.expectEqualStrings(
        "Nightcore 🛡️ Focus Mix",
        updated.targets[1].title,
    );
}

test "does not add a duplicate alias" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const initial = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
        },
    };

    try initial.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const library = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer library.deinit(std.testing.allocator);

    try std.testing.expectError(
        MusicLibraryError.DuplicateAlias,
        library.add(
            std.testing.io,
            std.testing.allocator,
            temp_dir.dir,
            "music_library.zon",
            .{
                .alias = "dusk",
                .title = "Different title",
                .kind = .track,
                .source = .youtube,
                .url = "https://www.youtube.com/watch?v=other",
            },
        ),
    );

    const unchanged = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer unchanged.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), unchanged.targets.len);
    try std.testing.expectEqualStrings("dusk", unchanged.targets[0].alias);
}

test "removes an existing alias" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const initial = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
            .{
                .alias = "dawn",
                .title = "Dawn Focus",
                .kind = .track,
                .source = .youtube,
                .url = "https://www.youtube.com/watch?v=example",
            },
        },
    };

    try initial.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const library = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer library.deinit(std.testing.allocator);

    const removed = try library.remove(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
        "dusk",
    );

    try std.testing.expect(removed);

    const updated = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer updated.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), updated.targets.len);
    try std.testing.expectEqualStrings("dawn", updated.targets[0].alias);
}

test "returns false and leaves library unchanged for missing alias" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const initial = MusicLibrary{
        .targets = &.{
            .{
                .alias = "dusk",
                .title = "Dusk Focus",
                .kind = .playlist,
                .source = .ytmusic,
                .url = "https://music.youtube.com/playlist?list=example",
            },
        },
    };

    try initial.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const library = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer library.deinit(std.testing.allocator);

    const removed = try library.remove(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
        "dawn",
    );

    try std.testing.expect(!removed);

    const unchanged = try MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer unchanged.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), unchanged.targets.len);
    try std.testing.expectEqualStrings("dusk", unchanged.targets[0].alias);
}
