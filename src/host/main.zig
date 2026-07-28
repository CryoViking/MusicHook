const std = @import("std");
const bridge_module = @import("bridge_module");
const native_message = bridge_module.frame;
const extension_protocol = bridge_module.protocol;
const utils_module = @import("utils_module");
const utils = utils_module.utils;
const runtime_env = utils_module.runtime_env;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var native_input_buffer: [4096]u8 = undefined;
    var native_output_buffer: [1024]u8 = undefined;
    var native_reader = std.Io.File.stdin().reader(io, &native_input_buffer);
    var native_writer = std.Io.File.stdout().writer(io, &native_output_buffer);

    const runtime_dir = try runtime_env.resolve_runtime_dir(
        allocator,
        init.environ_map.get("XDG_RUNTIME_DIR"),
        init.environ_map.get("TMPDIR"),
    );
    defer allocator.free(runtime_dir);

    const socket_path = try utils.runtime_socket_path(
        allocator,
        runtime_dir,
    );
    defer allocator.free(socket_path);

    const socket_dir_path = std.fs.path.dirname(socket_path) orelse
        return error.InvalidSocketPath;

    var socket_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        socket_dir_path,
        .{ .permissions = .fromMode(0o700) },
    );
    defer socket_dir.close(io);

    try remove_stale_socket(io, socket_path);
    const socket_address = try std.Io.net.UnixAddress.init(socket_path);
    var listener = try socket_address.listen(io, .{});
    defer {
        listener.deinit(io);
        std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    }

    while (true) {
        const client = try listener.accept(io);
        defer client.close(io);

        var client_input_buffer: [4096]u8 = undefined;
        var client_output_buffer: [1024]u8 = undefined;
        var client_reader = client.reader(io, &client_input_buffer);
        var client_writer = client.writer(io, &client_output_buffer);

        // Serve the client here.
        try relay_one(
            allocator,
            &client_reader.interface,
            &client_writer.interface,
            &native_reader.interface,
            &native_writer.interface,
        );
    }
}

fn remove_stale_socket(
    io: std.Io,
    socket_path: []const u8,
) !void {
    std.Io.Dir.deleteFileAbsolute(
        io,
        socket_path,
    ) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn relay_one(
    allocator: std.mem.Allocator,
    client_reader: *std.Io.Reader,
    client_writer: *std.Io.Writer,
    native_reader: *std.Io.Reader,
    native_writer: *std.Io.Writer,
) !void {
    const request_frame = try native_message.read_frame(allocator, client_reader);
    defer allocator.free(request_frame);

    const request_message = try native_message.NativeMessage.decode(request_frame);

    var parsed_request = try std.json.parseFromSlice(
        extension_protocol.Request,
        allocator,
        request_message.json_bytes,
        .{},
    );
    defer parsed_request.deinit();

    try parsed_request.value.validate();

    try native_message.write_frame(native_writer, request_frame);

    const response_frame = try native_message.read_frame(allocator, native_reader);
    defer allocator.free(response_frame);

    const response_message = try native_message.NativeMessage.decode(response_frame);
    var parsed_response = try std.json.parseFromSlice(
        extension_protocol.Response,
        allocator,
        response_message.json_bytes,
        .{},
    );
    defer parsed_response.deinit();

    try parsed_response.value.validate();
    try native_message.write_frame(client_writer, response_frame);
}

// SECTION: tests

test "runtime socket path joins an absolute runtime directory" {
    const path = try utils.runtime_socket_path(
        std.testing.allocator,
        "/run/user/1000",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/run/user/1000/music_hook/host.sock", path);
}

test "runtime socket path rejects a relative runtime directory" {
    try std.testing.expectError(
        error.RelativeRuntimeDirectory,
        utils.runtime_socket_path(
            std.testing.allocator,
            "relative/runtime",
        ),
    );
}
test "relays a play request to the extension and its response to the client" {
    const request_json = "{\"command\":\"play\",\"url\":\"https://music.youtube.com/watch?v=example\"}";
    const response_json = "{\"status\":\"ok\",\"error_code\":null}";

    const request_frame = try (native_message.NativeMessage{ .json_bytes = request_json }).encode(std.testing.allocator);
    defer std.testing.allocator.free(request_frame);

    const response_frame = try (native_message.NativeMessage{ .json_bytes = response_json }).encode(std.testing.allocator);
    defer std.testing.allocator.free(response_frame);

    var client_reader = std.Io.Reader.fixed(request_frame);
    var native_reader = std.Io.Reader.fixed(response_frame);

    var client_output_buffer: [256]u8 = undefined;
    var client_writer = std.Io.Writer.fixed(&client_output_buffer);

    var native_output_buffer: [256]u8 = undefined;
    var native_writer = std.Io.Writer.fixed(&native_output_buffer);

    try relay_one(
        std.testing.allocator,
        &client_reader,
        &client_writer,
        &native_reader,
        &native_writer,
    );

    try std.testing.expectEqualSlices(u8, request_frame, native_writer.buffered());
    try std.testing.expectEqualSlices(u8, response_frame, client_writer.buffered());
}

test "rejects an invalid client request before forwarding it" {
    const request_json = "{\"command\":\"play\",\"url\":\"\"}";
    const request_frame = try (native_message.NativeMessage{ .json_bytes = request_json }).encode(std.testing.allocator);
    defer std.testing.allocator.free(request_frame);

    var client_reader = std.Io.Reader.fixed(request_frame);
    var native_reader = std.Io.Reader.fixed("");

    var client_output_buffer: [256]u8 = undefined;
    var client_writer = std.Io.Writer.fixed(&client_output_buffer);

    var native_output_buffer: [256]u8 = undefined;
    var native_writer = std.Io.Writer.fixed(&native_output_buffer);

    try std.testing.expectError(
        extension_protocol.RequestError.EmptyUrl,
        relay_one(
            std.testing.allocator,
            &client_reader,
            &client_writer,
            &native_reader,
            &native_writer,
        ),
    );

    try std.testing.expectEqual(@as(usize, 0), native_writer.buffered().len);
}

test "rejects an invalid extension response before returning it to the client" {
    const request_json = "{\"command\":\"play\",\"url\":\"https://music.youtube.com/watch?v=example\"}";

    const response_json = "{\"status\":\"failed\",\"error_code\":null}";

    const request_frame = try (native_message.NativeMessage{ .json_bytes = request_json }).encode(std.testing.allocator);
    defer std.testing.allocator.free(request_frame);

    const response_frame = try (native_message.NativeMessage{ .json_bytes = response_json }).encode(std.testing.allocator);
    defer std.testing.allocator.free(response_frame);

    var client_reader = std.Io.Reader.fixed(request_frame);
    var native_reader = std.Io.Reader.fixed(response_frame);

    var client_output_buffer: [256]u8 = undefined;
    var client_writer = std.Io.Writer.fixed(&client_output_buffer);

    var native_output_buffer: [256]u8 = undefined;
    var native_writer = std.Io.Writer.fixed(&native_output_buffer);

    try std.testing.expectError(
        extension_protocol.ResponseError.MissingErrorCode,
        relay_one(
            std.testing.allocator,
            &client_reader,
            &client_writer,
            &native_reader,
            &native_writer,
        ),
    );

    try std.testing.expectEqualSlices(u8, request_frame, native_writer.buffered());
    try std.testing.expectEqual(@as(usize, 0), client_writer.buffered().len);
}

test "removes a stale Unix socket before listening" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    var runtime_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const runtime_dir_length = try temp_dir.dir.realPath(std.testing.io, &runtime_dir_buffer);

    const socket_path = try utils.runtime_socket_path(
        std.testing.allocator,
        runtime_dir_buffer[0..runtime_dir_length],
    );
    defer std.testing.allocator.free(socket_path);

    var socket_dir = try temp_dir.dir.createDirPathOpen(
        std.testing.io,
        "music_hook",
        .{ .permissions = .fromMode(0o700) },
    );
    socket_dir.close(std.testing.io);

    const socket_address = try std.Io.net.UnixAddress.init(socket_path);

    var stale_listener = try socket_address.listen(std.testing.io, .{});
    stale_listener.deinit(std.testing.io);

    try remove_stale_socket(std.testing.io, socket_path);

    var listener = try socket_address.listen(std.testing.io, .{});
    defer {
        listener.deinit(std.testing.io);
        std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    }
}

test "relays a ping request to the extension and its response to the client" {
    const request_json = "{\"command\":\"ping\",\"url\":null}";
    const response_json = "{\"status\":\"ok\",\"error_code\":null}";

    const request_frame = try (native_message.NativeMessage{ .json_bytes = request_json }).encode(std.testing.allocator);
    defer std.testing.allocator.free(request_frame);

    const response_frame = try (native_message.NativeMessage{ .json_bytes = response_json }).encode(std.testing.allocator);
    defer std.testing.allocator.free(response_frame);

    var client_reader = std.Io.Reader.fixed(request_frame);
    var native_reader = std.Io.Reader.fixed(response_frame);

    var client_output_buffer: [256]u8 = undefined;
    var client_writer = std.Io.Writer.fixed(&client_output_buffer);

    var native_output_buffer: [256]u8 = undefined;
    var native_writer = std.Io.Writer.fixed(&native_output_buffer);

    try relay_one(
        std.testing.allocator,
        &client_reader,
        &client_writer,
        &native_reader,
        &native_writer,
    );

    try std.testing.expectEqualSlices(u8, request_frame, native_writer.buffered());
    try std.testing.expectEqualSlices(u8, response_frame, client_writer.buffered());
}
