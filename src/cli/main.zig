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
        }
        return 1; // return a non-zero exit code
    }
}

fn execute(
    context: ExecutionContext,
    request: protocol.Request,
) !void {
    switch (request.command) {
        .init => try execute_init(
            context.io,
            context.allocator,
            context.config_filepath,
        ),
        .play => {
            const play_target = request.play_target orelse
                return protocol.ProtocolError.MissingPlayTarget;
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
        else => stub(),
    }
}

fn stub() void {
    std.debug.print("Stubbed command, doesn't exist yet\n", .{});
}

// SECTION: 'init' subcommand
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

// SECTION: 'play' subcommand
fn execute_handle_unsupported_url(url: []const u8) void {
    std.debug.print("Does not supported given url: {s}\n", .{url});
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
    const response_json =
        "{\"status\":\"ok\",\"error_code\":null}";

    const response_frame = try (bridge_frame.NativeMessage{
        .json_bytes = response_json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(response_frame);

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var runtime_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir_length = try temp_dir.dir.realPath(
        std.testing.io,
        &runtime_dir_buffer,
    );
    const runtime_dir = runtime_dir_buffer[0..runtime_dir_length];

    var socket_dir = try temp_dir.dir.createDirPathOpen(
        std.testing.io,
        "music_hook",
        .{
            .permissions = .fromMode(0o700),
        },
    );
    defer socket_dir.close(std.testing.io);

    const socket_path = try utils.runtime_socket_path(
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer std.testing.allocator.free(socket_path);

    const socket_address = try std.Io.net.UnixAddress.init(socket_path);

    var listener = try socket_address.listen(std.testing.io, .{});
    defer {
        listener.deinit(std.testing.io);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    }

    const FakeHost = struct {
        listener: *std.Io.net.Server,
        response_frame: []const u8,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            const client = try self.listener.accept(std.testing.io);
            defer client.close(std.testing.io);

            var input_buffer: [4096]u8 = undefined;
            var reader = client.reader(std.testing.io, &input_buffer);

            const request_frame = try bridge_frame.read_frame(
                std.testing.allocator,
                &reader.interface,
            );
            defer std.testing.allocator.free(request_frame);

            const request_message = try bridge_frame.NativeMessage.decode(
                request_frame,
            );

            var parsed_request = try std.json.parseFromSlice(
                bridge_protocol.Request,
                std.testing.allocator,
                request_message.json_bytes,
                .{},
            );
            defer parsed_request.deinit();

            try parsed_request.value.validate();
            try std.testing.expectEqual(
                bridge_protocol.Command.play,
                parsed_request.value.command,
            );
            try std.testing.expectEqualStrings(
                "https://music.youtube.com/watch?v=example",
                parsed_request.value.url,
            );

            var output_buffer: [1024]u8 = undefined;
            var writer = client.writer(std.testing.io, &output_buffer);
            try bridge_frame.write_frame(
                &writer.interface,
                self.response_frame,
            );
        }
    };

    var fake_host = FakeHost{
        .listener = &listener,
        .response_frame = response_frame,
    };

    const server_thread = try std.Thread.spawn(
        .{},
        FakeHost.run,
        .{&fake_host},
    );

    var joined = false;
    defer {
        if (!joined) server_thread.join();
    }

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = runtime_dir,
    };

    try execute_play_direct_url(
        context,
        "https://music.youtube.com/watch?v=example",
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;
}

test "direct URL play maps zen_unavailable to a CLI error" {
    const response_json =
        "{\"status\":\"failed\",\"error_code\":\"zen_unavailable\"}";

    const response_frame = try (bridge_frame.NativeMessage{
        .json_bytes = response_json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(response_frame);

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var runtime_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir_length = try temp_dir.dir.realPath(
        std.testing.io,
        &runtime_dir_buffer,
    );
    const runtime_dir = runtime_dir_buffer[0..runtime_dir_length];

    var socket_dir = try temp_dir.dir.createDirPathOpen(
        std.testing.io,
        "music_hook",
        .{
            .permissions = .fromMode(0o700),
        },
    );
    defer socket_dir.close(std.testing.io);

    const socket_path = try utils.runtime_socket_path(
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer std.testing.allocator.free(socket_path);

    const socket_address = try std.Io.net.UnixAddress.init(socket_path);

    var listener = try socket_address.listen(std.testing.io, .{});
    defer {
        listener.deinit(std.testing.io);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    }

    const FakeHost = struct {
        listener: *std.Io.net.Server,
        response_frame: []const u8,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            const client = try self.listener.accept(std.testing.io);
            defer client.close(std.testing.io);

            var input_buffer: [4096]u8 = undefined;
            var reader = client.reader(std.testing.io, &input_buffer);

            const request_frame = try bridge_frame.read_frame(
                std.testing.allocator,
                &reader.interface,
            );
            defer std.testing.allocator.free(request_frame);

            const request_message = try bridge_frame.NativeMessage.decode(
                request_frame,
            );

            var parsed_request = try std.json.parseFromSlice(
                bridge_protocol.Request,
                std.testing.allocator,
                request_message.json_bytes,
                .{},
            );
            defer parsed_request.deinit();

            try parsed_request.value.validate();
            try std.testing.expectEqual(
                bridge_protocol.Command.play,
                parsed_request.value.command,
            );
            try std.testing.expectEqualStrings(
                "https://music.youtube.com/watch?v=example",
                parsed_request.value.url,
            );

            var output_buffer: [1024]u8 = undefined;
            var writer = client.writer(std.testing.io, &output_buffer);
            try bridge_frame.write_frame(
                &writer.interface,
                self.response_frame,
            );
        }
    };

    var fake_host = FakeHost{
        .listener = &listener,
        .response_frame = response_frame,
    };

    const server_thread = try std.Thread.spawn(
        .{},
        FakeHost.run,
        .{&fake_host},
    );

    var joined = false;
    defer {
        if (!joined) server_thread.join();
    }

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = runtime_dir,
    };

    try std.testing.expectError(
        error.ZenUnavailable,
        execute_play_direct_url(
            context,
            "https://music.youtube.com/watch?v=example",
        ),
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;
}

test "direct URL play maps extension_unavailable to a CLI error" {
    const response_json =
        "{\"status\":\"failed\",\"error_code\":\"extension_unavailable\"}";

    const response_frame = try (bridge_frame.NativeMessage{
        .json_bytes = response_json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(response_frame);

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var runtime_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir_length = try temp_dir.dir.realPath(
        std.testing.io,
        &runtime_dir_buffer,
    );
    const runtime_dir = runtime_dir_buffer[0..runtime_dir_length];

    var socket_dir = try temp_dir.dir.createDirPathOpen(
        std.testing.io,
        "music_hook",
        .{
            .permissions = .fromMode(0o700),
        },
    );
    defer socket_dir.close(std.testing.io);

    const socket_path = try utils.runtime_socket_path(
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer std.testing.allocator.free(socket_path);

    const socket_address = try std.Io.net.UnixAddress.init(socket_path);

    var listener = try socket_address.listen(std.testing.io, .{});
    defer {
        listener.deinit(std.testing.io);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    }

    const FakeHost = struct {
        listener: *std.Io.net.Server,
        response_frame: []const u8,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            const client = try self.listener.accept(std.testing.io);
            defer client.close(std.testing.io);

            var input_buffer: [4096]u8 = undefined;
            var reader = client.reader(std.testing.io, &input_buffer);

            const request_frame = try bridge_frame.read_frame(
                std.testing.allocator,
                &reader.interface,
            );
            defer std.testing.allocator.free(request_frame);

            const request_message = try bridge_frame.NativeMessage.decode(
                request_frame,
            );

            var parsed_request = try std.json.parseFromSlice(
                bridge_protocol.Request,
                std.testing.allocator,
                request_message.json_bytes,
                .{},
            );
            defer parsed_request.deinit();

            try parsed_request.value.validate();
            try std.testing.expectEqual(
                bridge_protocol.Command.play,
                parsed_request.value.command,
            );
            try std.testing.expectEqualStrings(
                "https://music.youtube.com/watch?v=example",
                parsed_request.value.url,
            );

            var output_buffer: [1024]u8 = undefined;
            var writer = client.writer(std.testing.io, &output_buffer);
            try bridge_frame.write_frame(
                &writer.interface,
                self.response_frame,
            );
        }
    };

    var fake_host = FakeHost{
        .listener = &listener,
        .response_frame = response_frame,
    };

    const server_thread = try std.Thread.spawn(
        .{},
        FakeHost.run,
        .{&fake_host},
    );

    var joined = false;
    defer {
        if (!joined) server_thread.join();
    }

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = runtime_dir,
    };

    try std.testing.expectError(
        error.ExtensionUnavailable,
        execute_play_direct_url(
            context,
            "https://music.youtube.com/watch?v=example",
        ),
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;
}

test "direct URL play maps playback_failed to a CLI error" {
    const response_json =
        "{\"status\":\"failed\",\"error_code\":\"playback_failed\"}";

    const response_frame = try (bridge_frame.NativeMessage{
        .json_bytes = response_json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(response_frame);

    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var runtime_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir_length = try temp_dir.dir.realPath(
        std.testing.io,
        &runtime_dir_buffer,
    );
    const runtime_dir = runtime_dir_buffer[0..runtime_dir_length];

    var socket_dir = try temp_dir.dir.createDirPathOpen(
        std.testing.io,
        "music_hook",
        .{
            .permissions = .fromMode(0o700),
        },
    );
    defer socket_dir.close(std.testing.io);

    const socket_path = try utils.runtime_socket_path(
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer std.testing.allocator.free(socket_path);

    const socket_address = try std.Io.net.UnixAddress.init(socket_path);

    var listener = try socket_address.listen(std.testing.io, .{});
    defer {
        listener.deinit(std.testing.io);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    }

    const FakeHost = struct {
        listener: *std.Io.net.Server,
        response_frame: []const u8,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.err = err;
            };
        }

        fn serve(self: *@This()) !void {
            const client = try self.listener.accept(std.testing.io);
            defer client.close(std.testing.io);

            var input_buffer: [4096]u8 = undefined;
            var reader = client.reader(std.testing.io, &input_buffer);

            const request_frame = try bridge_frame.read_frame(
                std.testing.allocator,
                &reader.interface,
            );
            defer std.testing.allocator.free(request_frame);

            const request_message = try bridge_frame.NativeMessage.decode(
                request_frame,
            );

            var parsed_request = try std.json.parseFromSlice(
                bridge_protocol.Request,
                std.testing.allocator,
                request_message.json_bytes,
                .{},
            );
            defer parsed_request.deinit();

            try parsed_request.value.validate();
            try std.testing.expectEqual(
                bridge_protocol.Command.play,
                parsed_request.value.command,
            );
            try std.testing.expectEqualStrings(
                "https://music.youtube.com/watch?v=example",
                parsed_request.value.url,
            );

            var output_buffer: [1024]u8 = undefined;
            var writer = client.writer(std.testing.io, &output_buffer);
            try bridge_frame.write_frame(
                &writer.interface,
                self.response_frame,
            );
        }
    };

    var fake_host = FakeHost{
        .listener = &listener,
        .response_frame = response_frame,
    };

    const server_thread = try std.Thread.spawn(
        .{},
        FakeHost.run,
        .{&fake_host},
    );

    var joined = false;
    defer {
        if (!joined) server_thread.join();
    }

    const context = ExecutionContext{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .config_filepath = "",
        .xdg_runtime_dir = null,
        .temp_dir = runtime_dir,
    };

    try std.testing.expectError(
        error.PlaybackFailed,
        execute_play_direct_url(
            context,
            "https://music.youtube.com/watch?v=example",
        ),
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;
}
