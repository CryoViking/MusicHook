const std = @import("std");

pub const ConfigError = error{
    EmptyDataPath,
    RelativeDataPath,
};

pub const Config = struct {
    data_path: []const u8,

    pub fn validate(self: Config) ConfigError!void {
        if (self.data_path.len == 0) return ConfigError.EmptyDataPath;
        if (!std.fs.path.isAbsolute(self.data_path))
            return ConfigError.RelativeDataPath;
    }

    pub fn load(
        io: std.Io,
        allocator: std.mem.Allocator,
        dir: std.Io.Dir,
        path: []const u8,
    ) !Config {
        const contents = try dir.readFileAllocOptions(
            io,
            path,
            allocator,
            .limited(1024 * 1024),
            .of(u8),
            0,
        );
        defer allocator.free(contents);

        const config = try std.zon.parse.fromSliceAlloc(
            Config,
            allocator,
            contents,
            null,
            .{},
        );
        errdefer std.zon.parse.free(allocator, config);

        try config.validate();
        return config;
    }

    pub fn write_new(
        self: Config,
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

        var zon_config = try serializer.beginStruct(.{
            .whitespace_style = .{ .wrap = true },
        });
        try zon_config.field("data_path", self.data_path, .{});
        try zon_config.end();

        try output.writer.writeByte('\n');

        try dir.writeFile(io, .{
            .sub_path = path,
            .data = output.writer.buffered(),
            .flags = .{
                .exclusive = true,
            },
        });
    }

    pub fn deinit(
        self: Config,
        allocator: std.mem.Allocator,
    ) void {
        std.zon.parse.free(allocator, self);
    }
};

test "valid data path in config" {
    const config = Config{
        .data_path = "/home/shiori/.config/music_hook/data",
    };

    try config.validate();
}

test "empty data path is invalid" {
    const config = Config{
        .data_path = "",
    };

    try std.testing.expectError(
        ConfigError.EmptyDataPath,
        config.validate(),
    );
}

test "relative data path is invalid" {
    const config = Config{
        .data_path = "~/.config/music_hook/data",
    };

    try std.testing.expectError(
        ConfigError.RelativeDataPath,
        config.validate(),
    );
}

test "reads valid config fixture" {
    const config = try Config.load(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        "testdata/config.zon",
    );
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "/home/shiori/.config/music_hook/data",
        config.data_path,
    );
}

test "writes config that can be loaded" {
    // This creates a directory in .zig_cache/tmp
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const expected = Config{
        .data_path = "/home/shiori/.config/music_hook/data",
    };

    try expected.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "config.zon",
    );

    const actual = try Config.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "config.zon",
    );
    defer actual.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        expected.data_path,
        actual.data_path,
    );
}

test "does not overwrite an existing config" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const config = Config{
        .data_path = "/home/shiori/.config/music_hook/data",
    };

    try config.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "config.zon",
    );

    try std.testing.expectError(
        error.PathAlreadyExists,
        config.write_new(
            std.testing.io,
            std.testing.allocator,
            temp_dir.dir,
            "config.zon",
        ),
    );
}
