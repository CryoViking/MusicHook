const std = @import("std");
const cli = @import("cli.zig");
const protocol = @import("protocol.zig");
const library_module = @import("library_module");
const music_library = library_module.music_library;
const config = library_module.config;
const utils_module = @import("utils_module");
const utils = utils_module.utils;
const host_client = @import("host_client.zig");
const bridge_module = @import("bridge_module");
const bridge_protocol = bridge_module.protocol;
const bridge_frame = bridge_module.frame;
const test_support = @import("_test_support.zig");
const target_resolver = @import("target_resolver.zig");

const PlayTargetKind = union(enum) {
    alias: []const u8,
    direct_url: []const u8,
    unsupported_url: []const u8,
};

const SetupError = error{
    NotInitialized,
    DataDirectoryMissing,
    LibraryMissing,
};

const AddError = error{
    AliasAlreadyExists,
};

const RemoveResult = enum {
    removed,
    not_found,
};

const ExecutionContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config_filepath: []const u8,
    xdg_runtime_dir: ?[]const u8,
    temp_dir: ?[]const u8,
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
        const path = try config_path(allocator, home);
        defer allocator.free(path);

        const context = ExecutionContext{
            .io = init.io,
            .allocator = init.gpa,
            .config_filepath = path,
            .xdg_runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
            .temp_dir = init.environ_map.get("TMPDIR"),
        };

        execute(context, request) catch |err| switch (err) {
            SetupError.NotInitialized => {
                std.debug.print(
                    "MusicHook has not been initialized, Run `music init` first.\n",
                    .{},
                );
                return 1;
            },
            SetupError.DataDirectoryMissing => {
                std.debug.print(
                    "MusicHook's configured data directory is unavailable.\n",
                    .{},
                );
                return 1;
            },
            SetupError.LibraryMissing => {
                std.debug.print(
                    "MusicHook's data directory has no music_library.zon file.\n",
                    .{},
                );
                return 1;
            },
            AddError.AliasAlreadyExists => {
                std.debug.print(
                    "Alias already exists in library",
                    .{},
                );
                return 1;
            },
            else => |other| return other,
        };
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
            cli.ParseError.MissingAddAlias => {
                std.debug.print("No alias was given for add\n", .{});
            },
            cli.ParseError.MissingAddUrl => {
                std.debug.print("No URL was given for add\n", .{});
            },
            cli.ParseError.MissingRemoveAlias => {
                std.debug.print("No alias was given for remove\n", .{});
            },
        }
        return 1; // return a non-zero exit code
    }
}

fn execute(
    context: ExecutionContext,
    request: protocol.Request,
) !void {
    switch (request) {
        .init => try execute_init(
            context.io,
            context.allocator,
            context.config_filepath,
        ),
        .play => |play_target| {
            switch (classify_play_target(play_target)) {
                .unsupported_url => |url| {
                    execute_handle_unsupported_url(url);
                },
                .direct_url => |url| {
                    try execute_play_direct_url(context, url);
                    std.debug.print("Playback started.\n", .{});
                },
                .alias => |alias| {
                    const cfg = config.Config.load(
                        context.io,
                        context.allocator,
                        std.Io.Dir.cwd(),
                        context.config_filepath,
                    ) catch |err| switch (err) {
                        error.FileNotFound => return SetupError.NotInitialized,
                        else => |other| return other,
                    };
                    defer cfg.deinit(context.allocator);

                    var data_dir = std.Io.Dir.openDirAbsolute(
                        context.io,
                        cfg.data_path,
                        .{},
                    ) catch |err| switch (err) {
                        error.FileNotFound, error.NotDir => {
                            return SetupError.DataDirectoryMissing;
                        },
                        else => |other| return other,
                    };
                    defer data_dir.close(context.io);

                    const library = music_library.MusicLibrary.load(
                        context.io,
                        context.allocator,
                        data_dir,
                        "music_library.zon",
                    ) catch |err| switch (err) {
                        error.FileNotFound => return SetupError.LibraryMissing,
                        else => |other| return other,
                    };
                    defer library.deinit(context.allocator);

                    execute_play_alias(library, alias);
                },
            }
        },
        .add => |add_request| {
            try execute_add(context, add_request);
        },
        .remove => |alias| {
            switch (try execute_remove(context, alias)) {
                .removed => {
                    std.debug.print("Removed alias: {s}\n", .{alias});
                },
                .not_found => {
                    std.debug.print("Alias not found: {s}\n", .{alias});
                },
            }
        },
        .pause => {
            try execute_playback_command(context, .pause);
            std.debug.print("Playback paused.\n", .{});
        },
        .@"resume" => {
            try execute_playback_command(context, .@"resume");
            std.debug.print("Playback resumed.\n", .{});
        },
        .sync, .list, .status => stub(),
    }
}

fn stub() void {
    std.debug.print("Stubbed command, doesn't exist yet\n", .{});
}

fn execute_init(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_filepath: []const u8,
) !void {
    const config_dir = std.fs.path.dirname(config_filepath) orelse
        return error.InvalidConfigPath;
    const default_data_path = try init_default_data_path(
        io,
        allocator,
        config_filepath,
    );
    defer allocator.free(default_data_path);

    var input_buffer: [4096]u8 = undefined;
    var output_buffer: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &input_buffer);
    var writer = std.Io.File.stdout().writer(io, &output_buffer);

    // Load existing config if it exists, and if it does
    // populate defaults with existing values.
    //
    // Allows for safe overwrite
    const data_path = try prompt_line_with_default(
        allocator,
        &reader.interface,
        &writer.interface,
        "Data Library path",
        default_data_path,
    );
    defer allocator.free(data_path);

    const cfg = config.Config{
        .data_path = data_path,
    };

    try cfg.validate();

    var data_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        cfg.data_path,
        .{},
    );
    defer data_dir.close(io);

    const existing_music_library = music_library.MusicLibrary.load(
        io,
        allocator,
        data_dir,
        "music_library.zon",
    ) catch |err| switch (err) {
        error.FileNotFound => null, // like "pass" in python
        else => |other| return other,
    };
    if (existing_music_library) |library| {
        defer library.deinit(allocator);
    } else {
        const library = music_library.MusicLibrary{
            .targets = &.{},
        };

        try library.write_new(
            io,
            allocator,
            data_dir,
            "music_library.zon",
        );
    }

    try std.Io.Dir.cwd().createDirPath(io, config_dir);

    try cfg.write(
        io,
        allocator,
        std.Io.Dir.cwd(),
        config_filepath,
    );

    try writer.interface.print(
        "\nMusicHook is initialised.\n" ++
            "Next: install the web extension, then run:\n" ++
            "  music play <YouTube URL>\n",
        .{},
    );
    try writer.interface.flush();
}

fn init_default_data_path(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_filepath: []const u8,
) ![]u8 {
    const existing_cfg = config.Config.load(
        io,
        allocator,
        std.Io.Dir.cwd(),
        config_filepath,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            const config_dir = std.fs.path.dirname(config_filepath) orelse
                return error.InvalidConfigPath;

            return std.fs.path.join(allocator, &.{
                config_dir,
                "data",
            });
        },
        else => |other| return other,
    };
    defer existing_cfg.deinit(allocator);

    return allocator.dupe(u8, existing_cfg.data_path);
}

fn execute_handle_unsupported_url(url: []const u8) void {
    std.debug.print("Does not supported given url: {s}\n", .{url});
}

fn execute_playback_command(
    context: ExecutionContext,
    command: bridge_protocol.Command,
) !void {
    var client = try host_client.HostClient.connect(
        context.io,
        context.allocator,
        context.xdg_runtime_dir,
        context.temp_dir,
    );
    defer client.deinit();

    const response = try client.send(
        context.allocator,
        .{
            .command = command,
        },
    );

    switch (response.status) {
        .ok => {},
        .failed => switch (response.error_code.?) {
            .extension_unavailable => return error.ExtensionUnavailable,
            .zen_unavailable => return error.ZenUnavailable,
            .playback_failed => return error.PlaybackFailed,
        },
    }
}

fn execute_play_direct_url(context: ExecutionContext, url: []const u8) !void {
    var client = try host_client.HostClient.connect(
        context.io,
        context.allocator,
        context.xdg_runtime_dir,
        context.temp_dir,
    );
    defer client.deinit();

    const response = try client.send(
        context.allocator,
        .{
            .command = .play,
            .url = url,
        },
    );

    switch (response.status) {
        .ok => {},
        .failed => switch (response.error_code.?) {
            .extension_unavailable => return error.ExtensionUnavailable,
            .zen_unavailable => return error.ZenUnavailable,
            .playback_failed => return error.PlaybackFailed,
        },
    }
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

fn execute_add(
    context: ExecutionContext,
    request: protocol.AddRequest,
) !void {
    const cfg = config.Config.load(
        context.io,
        context.allocator,
        std.Io.Dir.cwd(),
        context.config_filepath,
    ) catch |err| switch (err) {
        error.FileNotFound => return SetupError.NotInitialized,
        else => |other| return other,
    };
    defer cfg.deinit(context.allocator);

    var data_dir = std.Io.Dir.openDirAbsolute(
        context.io,
        cfg.data_path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            return SetupError.DataDirectoryMissing;
        },
        else => |other| return other,
    };
    defer data_dir.close(context.io);

    const library = music_library.MusicLibrary.load(
        context.io,
        context.allocator,
        data_dir,
        "music_library.zon",
    ) catch |err| switch (err) {
        error.FileNotFound => return SetupError.LibraryMissing,
        else => |other| return other,
    };
    defer library.deinit(context.allocator);

    if (library.find(request.alias) != null) return AddError.AliasAlreadyExists;

    const resolved = try target_resolver.resolve(
        context.io,
        context.allocator,
        request.alias,
        request.url,
    );
    defer resolved.deinit(context.allocator);

    try library.add(
        context.io,
        context.allocator,
        data_dir,
        "music_library.zon",
        resolved.target,
    );

    std.debug.print(
        "Added {s}: {s}\n",
        .{
            resolved.target.alias,
            resolved.target.title,
        },
    );
}

fn execute_remove(context: ExecutionContext, alias: []const u8) !RemoveResult {
    const cfg = config.Config.load(
        context.io,
        context.allocator,
        std.Io.Dir.cwd(),
        context.config_filepath,
    ) catch |err| switch (err) {
        error.FileNotFound => return SetupError.NotInitialized,
        else => |other| return other,
    };
    defer cfg.deinit(context.allocator);

    var data_dir = std.Io.Dir.openDirAbsolute(
        context.io,
        cfg.data_path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            return SetupError.DataDirectoryMissing;
        },
        else => |other| return other,
    };
    defer data_dir.close(context.io);

    const library = music_library.MusicLibrary.load(
        context.io,
        context.allocator,
        data_dir,
        "music_library.zon",
    ) catch |err| switch (err) {
        error.FileNotFound => return SetupError.LibraryMissing,
        else => |other| return other,
    };
    defer library.deinit(context.allocator);

    const removed = try library.remove(
        context.io,
        context.allocator,
        data_dir,
        "music_library.zon",
        alias,
    );

    return if (removed) .removed else .not_found;
}

fn config_path(
    allocator: std.mem.Allocator,
    home: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fs.path.join(allocator, &.{
        home,
        ".config",
        "music_hook",
        "config.zon",
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

fn prompt_line(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    question: []const u8,
) ![]u8 {
    try writer.print("{s}", .{question});
    try writer.flush();

    const line = (try reader.takeDelimiter('\n')) orelse
        return error.EndOfStream;

    const answer = std.mem.trimEnd(u8, line, "\r");
    return allocator.dupe(u8, answer);
}

fn prompt_line_with_default(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    label: []const u8,
    default_value: []const u8,
) ![]u8 {
    try writer.print("{s} [{s}]:", .{
        label,
        default_value,
    });
    try writer.flush();

    const line = (try reader.takeDelimiter('\n')) orelse
        return error.EndOfStream;

    const answer = std.mem.trimEnd(
        u8,
        line,
        "\r",
    );
    if (answer.len == 0) return allocator.dupe(u8, default_value);
    return allocator.dupe(u8, answer);
}

// SECTION: Test Harness
test "config_path builds the config location" {
    const path = try config_path(
        std.testing.allocator,
        "/home/shiori",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(
        "/home/shiori/.config/music_hook/config.zon",
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

test "prompt_line writes a question and returns the answer" {
    var reader = std.Io.Reader.fixed(
        "/home/shiori/.config/music_hook/data\n",
    );

    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    const answer = try prompt_line(
        std.testing.allocator,
        &reader,
        &writer,
        "Where would you like to store your data library? ",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings(
        "/home/shiori/.config/music_hook/data",
        answer,
    );
    try std.testing.expectEqualStrings(
        "Where would you like to store your data library? ",
        writer.buffered(),
    );
}

test "prompt_line_with_default accepts \n" {
    var reader = std.Io.Reader.fixed(
        "\n",
    );

    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    const answer = try prompt_line_with_default(
        std.testing.allocator,
        &reader,
        &writer,
        "LABEL",
        "DEFAULT",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings(
        "DEFAULT",
        answer,
    );
    try std.testing.expectEqualStrings(
        "LABEL [DEFAULT]:",
        writer.buffered(),
    );
}

test "prompt_line_with_default overrides default" {
    var reader = std.Io.Reader.fixed(
        "NOT_DEFAULT",
    );

    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    const answer = try prompt_line_with_default(
        std.testing.allocator,
        &reader,
        &writer,
        "LABEL",
        "DEFAULT",
    );
    defer std.testing.allocator.free(answer);

    try std.testing.expectEqualStrings(
        "NOT_DEFAULT",
        answer,
    );
    try std.testing.expectEqualStrings(
        "LABEL [DEFAULT]:",
        writer.buffered(),
    );
}

test "direct URL play succeeds when the host returns ok" {
    const expected_url =
        "https://music.youtube.com/watch?v=example";

    var fake_host = try test_support.FakeHost.start(
        "{\"status\":\"ok\",\"error_code\":null}",
        .{ .command = .play, .url = expected_url },
    );
    defer fake_host.deinit();

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = fake_host.runtime_dir,
    };

    try execute_play_direct_url(context, expected_url);

    try fake_host.join();
}

test "direct URL play maps zen_unavailable to a CLI error" {
    const expected_url =
        "https://music.youtube.com/watch?v=example";

    var fake_host = try test_support.FakeHost.start(
        "{\"status\":\"failed\",\"error_code\":\"zen_unavailable\"}",
        .{ .command = .play, .url = expected_url },
    );
    defer fake_host.deinit();

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = fake_host.runtime_dir,
    };

    try std.testing.expectError(
        error.ZenUnavailable,
        execute_play_direct_url(context, expected_url),
    );

    try fake_host.join();
}

test "direct URL play maps extension_unavailable to a CLI error" {
    const expected_url =
        "https://music.youtube.com/watch?v=example";

    var fake_host = try test_support.FakeHost.start(
        "{\"status\":\"failed\",\"error_code\":\"extension_unavailable\"}",
        .{ .command = .play, .url = expected_url },
    );
    defer fake_host.deinit();

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = fake_host.runtime_dir,
    };

    try std.testing.expectError(
        error.ExtensionUnavailable,
        execute_play_direct_url(context, expected_url),
    );

    try fake_host.join();
}

test "direct URL play maps playback_failed to a CLI error" {
    const expected_url =
        "https://music.youtube.com/watch?v=example";

    var fake_host = try test_support.FakeHost.start(
        "{\"status\":\"failed\",\"error_code\":\"playback_failed\"}",
        .{ .command = .play, .url = expected_url },
    );
    defer fake_host.deinit();

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = fake_host.runtime_dir,
    };

    try std.testing.expectError(
        error.PlaybackFailed,
        execute_play_direct_url(context, expected_url),
    );

    try fake_host.join();
}

test "pause succeeds when the host returns ok" {
    var fake_host = try test_support.FakeHost.start(
        "{\"status\":\"ok\",\"error_code\":null}",
        .{ .command = .pause },
    );
    defer fake_host.deinit();

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = fake_host.runtime_dir,
    };

    try execute_playback_command(context, .pause);

    try fake_host.join();
}

test "resume succeeds when the host returns ok" {
    var fake_host = try test_support.FakeHost.start(
        "{\"status\":\"ok\",\"error_code\":null}",
        .{ .command = .@"resume" },
    );
    defer fake_host.deinit();

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = fake_host.runtime_dir,
    };

    try execute_playback_command(context, .@"resume");

    try fake_host.join();
}

test "pause maps playback_failed to a CLI error" {
    var fake_host = try test_support.FakeHost.start(
        "{\"status\":\"failed\",\"error_code\":\"playback_failed\"}",
        .{ .command = .pause },
    );
    defer fake_host.deinit();

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = fake_host.runtime_dir,
    };

    try std.testing.expectError(
        error.PlaybackFailed,
        execute_playback_command(context, .pause),
    );

    try fake_host.join();
}

test "add rejects an existing alias before resolving its URL" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var data_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_path_length = try temp_dir.dir.realPath(
        std.testing.io,
        &data_path_buffer,
    );

    const data_path = try std.testing.allocator.dupe(
        u8,
        data_path_buffer[0..data_path_length],
    );
    defer std.testing.allocator.free(data_path);

    const config_filepath = try std.fs.path.join(
        std.testing.allocator,
        &.{ data_path, "config.zon" },
    );
    defer std.testing.allocator.free(config_filepath);

    const cfg = config.Config{
        .data_path = data_path,
    };

    try cfg.write_new(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        config_filepath,
    );

    const initial_library = music_library.MusicLibrary{
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

    try initial_library.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = config_filepath,
        .xdg_runtime_dir = null,
        .temp_dir = null,
    };

    try std.testing.expectError(
        AddError.AliasAlreadyExists,
        execute_add(context, .{
            .alias = "dusk",
            .url = "https://example.com/not-used",
        }),
    );
}

test "remove deletes an existing alias" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var data_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_path_length = try temp_dir.dir.realPath(
        std.testing.io,
        &data_path_buffer,
    );

    const data_path = try std.testing.allocator.dupe(
        u8,
        data_path_buffer[0..data_path_length],
    );
    defer std.testing.allocator.free(data_path);

    const config_filepath = try std.fs.path.join(
        std.testing.allocator,
        &.{ data_path, "config.zon" },
    );
    defer std.testing.allocator.free(config_filepath);

    const cfg = config.Config{ .data_path = data_path };
    try cfg.write_new(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        config_filepath,
    );

    const initial_library = music_library.MusicLibrary{
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

    try initial_library.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = config_filepath,
        .xdg_runtime_dir = null,
        .temp_dir = null,
    };

    try std.testing.expectEqual(
        RemoveResult.removed,
        try execute_remove(context, "dawn"),
    );

    const updated = try music_library.MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer updated.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), updated.targets.len);
    try std.testing.expectEqualStrings("dusk", updated.targets[0].alias);
}

test "remove leaves the library unchanged for a missing alias" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var data_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_path_length = try temp_dir.dir.realPath(
        std.testing.io,
        &data_path_buffer,
    );

    const data_path = try std.testing.allocator.dupe(
        u8,
        data_path_buffer[0..data_path_length],
    );
    defer std.testing.allocator.free(data_path);

    const config_filepath = try std.fs.path.join(std.testing.allocator, &.{ data_path, "config.zon" });
    defer std.testing.allocator.free(config_filepath);

    const cfg = config.Config{ .data_path = data_path };
    try cfg.write_new(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        config_filepath,
    );

    const initial_library = music_library.MusicLibrary{
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

    try initial_library.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = config_filepath,
        .xdg_runtime_dir = null,
        .temp_dir = null,
    };

    try std.testing.expectEqual(
        RemoveResult.not_found,
        try execute_remove(context, "dawn"),
    );

    const unchanged = try music_library.MusicLibrary.load(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );
    defer unchanged.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), unchanged.targets.len);
    try std.testing.expectEqualStrings("dusk", unchanged.targets[0].alias);
}
