const std = @import("std");
const bridge_module = @import("bridge_module");
const bridge_frame = bridge_module.frame;
const bridge_protocol = bridge_module.protocol;
const utils_module = @import("utils_module");
const utils = utils_module.utils;

pub const HostClient = struct {
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn connect(
        io: std.Io,
        allocator: std.mem.Allocator,
        xdg_runtime_dir: ?[]const u8,
        temp_dir: ?[]const u8,
    ) !HostClient {
        const socket_path = try utils.runtime_socket_path(
            allocator,
            xdg_runtime_dir,
            temp_dir,
        );
        defer allocator.free(socket_path);

        const socket_address = try std.Io.net.UnixAddress.init(
            socket_path,
        );

        return .{
            .io = io,
            .stream = try socket_address.connect(io),
        };
    }

    pub fn deinit(self: *HostClient) void {
        self.stream.close(self.io);
        self.* = undefined;
    }

    pub fn send(
        self: *HostClient,
        allocator: std.mem.Allocator,
        request: bridge_protocol.Request,
    ) !bridge_protocol.Response {
        try request.validate();

        var output = std.Io.Writer.Allocating.init(allocator);
        errdefer output.deinit();

        try std.json.Stringify.value(
            request,
            .{},
            &output.writer,
        );

        const request_json = try output.toOwnedSlice();
        defer allocator.free(request_json);

        const request_frame = try (bridge_frame.NativeMessage{
            .json_bytes = request_json,
        }).encode(allocator);
        defer allocator.free(request_frame);

        var output_buffer: [1024]u8 = undefined;
        var writer = self.stream.writer(self.io, &output_buffer);
        try bridge_frame.write_frame(&writer.interface, request_frame);

        var input_buffer: [4096]u8 = undefined;
        var reader = self.stream.reader(self.io, &input_buffer);
        const response_frame = try bridge_frame.read_frame(
            allocator,
            &reader.interface,
        );
        defer allocator.free(response_frame);

        const response_message = try bridge_frame.NativeMessage.decode(
            response_frame,
        );

        var parsed_response = try std.json.parseFromSlice(
            bridge_protocol.Response,
            allocator,
            response_message.json_bytes,
            .{},
        );
        defer parsed_response.deinit();

        const response = parsed_response.value;
        try response.validate();
        return response;
    }
};

test "HostClient sends a play request over a Unix socket and receives a response" {
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
            try bridge_frame.write_frame(&writer.interface, self.response_frame);
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

    var client = try HostClient.connect(
        std.testing.io,
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer client.deinit();

    const response = try client.send(
        std.testing.allocator,
        .{
            .command = .play,
            .url = "https://music.youtube.com/watch?v=example",
        },
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;

    try std.testing.expectEqual(
        bridge_protocol.ResponseStatus.ok,
        response.status,
    );
    try std.testing.expectEqual(
        @as(?bridge_protocol.ErrorCode, null),
        response.error_code,
    );
}

test "HostClient returns a failed response from the host" {
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
            try bridge_frame.write_frame(&writer.interface, self.response_frame);
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

    var client = try HostClient.connect(
        std.testing.io,
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer client.deinit();

    const response = try client.send(
        std.testing.allocator,
        .{
            .command = .play,
            .url = "https://music.youtube.com/watch?v=example",
        },
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;
    try std.testing.expectEqual(
        bridge_protocol.ResponseStatus.failed,
        response.status,
    );
    try std.testing.expectEqual(
        @as(?bridge_protocol.ErrorCode, .zen_unavailable),
        response.error_code,
    );
}

test "HostClient rejects a failed response without an error code" {
    const response_json =
        "{\"status\":\"failed\",\"error_code\":null}";

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
            try bridge_frame.write_frame(&writer.interface, self.response_frame);
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

    var client = try HostClient.connect(
        std.testing.io,
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer client.deinit();

    try std.testing.expectError(
        bridge_protocol.ResponseError.MissingErrorCode,
        client.send(
            std.testing.allocator,
            .{
                .command = .play,
                .url = "https://music.youtube.com/watch?v=example",
            },
        ),
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;
}

test "HostClient rejects invalid JSON from the host" {
    const response_json = "{not json}";

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
            try bridge_frame.write_frame(&writer.interface, self.response_frame);
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

    var client = try HostClient.connect(
        std.testing.io,
        std.testing.allocator,
        null,
        runtime_dir,
    );
    defer client.deinit();

    try std.testing.expectError(
        error.SyntaxError,
        client.send(
            std.testing.allocator,
            .{
                .command = .play,
                .url = "https://music.youtube.com/watch?v=example",
            },
        ),
    );

    server_thread.join();
    joined = true;

    if (fake_host.err) |err| return err;
}
