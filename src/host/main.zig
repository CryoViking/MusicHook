const std = @import("std");
const bridge_module = @import("bridge_module");
const native_message = bridge_module.frame;
const extension_protocol = bridge_module.protocol;
const utils_module = @import("utils_module");
const utils = utils_module.utils;

const MAX_PAYLOAD_SIZE = 1024 * 1024;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    var native_input_buffer: [4096]u8 = undefined;
    var native_output_buffer: [1024]u8 = undefined;
    var native_reader = std.Io.File.stdin().reader(io, &native_input_buffer);
    var native_writer = std.Io.File.stdout().writer(io, &native_output_buffer);

    const socket_path = try utils.runtime_socket_path(
        allocator,
        init.environ_map.get("XDG_RUNTIME_DIR"),
        init.environ_map.get("TMPDIR"),
    );
    defer allocator.free(socket_path);

    const socket_dir_path = std.fs.path.dirname(socket_path) orelse
        return error.InvalidSocketPath;

    var socket_dir = try std.Io.Dir.cwd().createDirPathOpen(
        io,
        socket_dir_path,
        .{
            .permissions = .fromMode(0o700),
        },
    );
    defer socket_dir.close(io);

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
        const request_frame = try read_frame(
            allocator,
            &client_reader.interface,
        );
        defer allocator.free(request_frame);

        const request_message = try native_message.NativeMessage.decode(
            request_frame,
        );

        var parsed_request = try std.json.parseFromSlice(
            extension_protocol.Request,
            allocator,
            request_message.json_bytes,
            .{},
        );
        defer parsed_request.deinit();

        const request = parsed_request.value;
        try request.validate();

        try write_frame(&native_writer.interface, request_frame);

        const response_frame = try read_frame(
            allocator,
            &native_reader.interface,
        );
        defer allocator.free(response_frame);

        const response_message = try native_message.NativeMessage.decode(
            response_frame,
        );

        var parsed_response = try std.json.parseFromSlice(
            extension_protocol.Response,
            allocator,
            response_message.json_bytes,
            .{},
        );
        defer parsed_response.deinit();

        const response = parsed_response.value;
        try response.validate();

        try write_frame(&client_writer.interface, response_frame);
    }
}

pub fn read_frame(
    allocator: std.mem.Allocator,
    native_reader: *std.Io.Reader,
) ![]u8 {
    const header = try native_reader.take(@sizeOf(u32));
    const payload_size: usize = @intCast(std.mem.readInt(
        u32,
        header[0..@sizeOf(u32)],
        .native,
    ));

    if (payload_size > MAX_PAYLOAD_SIZE) {
        return error.PayloadTooLarge;
    }

    const frame = try allocator.alloc(
        u8,
        header.len + payload_size,
    );
    errdefer allocator.free(frame);

    @memcpy(frame[0..header.len], header);
    try native_reader.readSliceAll(frame[header.len..]);

    return frame;
}

pub fn write_frame(
    writer: *std.Io.Writer,
    frame: []const u8,
) !void {
    try writer.writeAll(frame);
    try writer.flush();
}

pub fn handle_request(
    request: extension_protocol.Request,
) extension_protocol.Response {
    switch (request.command) {
        .play => return .{
            .status = .failed,
            .error_code = .extension_unavailable,
        },
    }
}

pub fn process_frame(
    allocator: std.mem.Allocator,
    request_frame: []const u8,
) ![]u8 {
    const message = try native_message.NativeMessage.decode(request_frame);

    const response_json = try process_json(
        allocator,
        message.json_bytes,
    );
    defer allocator.free(response_json);

    return try (native_message.NativeMessage{
        .json_bytes = response_json,
    }).encode(allocator);
}

pub fn process_json(
    allocator: std.mem.Allocator,
    request_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(
        extension_protocol.Request,
        allocator,
        request_json,
        .{},
    );
    defer parsed.deinit();

    const request = parsed.value;
    try request.validate();

    const response = handle_request(request);
    try response.validate();

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();

    try std.json.Stringify.value(response, .{}, &output.writer);

    return try output.toOwnedSlice();
}

// SECTION: tests
test "valid play-request results in valid response" {
    const payload = "{\"command\":\"play\",\"url\":\"https://music.youtube.com/watch?v=example\"}";
    const response_json = try process_json(
        std.testing.allocator,
        payload,
    );
    defer std.testing.allocator.free(response_json);

    var parsed_response = try std.json.parseFromSlice(
        extension_protocol.Response,
        std.testing.allocator,
        response_json,
        .{},
    );
    defer parsed_response.deinit();
    const response = parsed_response.value;
    try response.validate();

    try std.testing.expectEqual(
        extension_protocol.ResponseStatus.failed,
        response.status,
    );
    try std.testing.expectEqual(
        extension_protocol.ErrorCode.extension_unavailable,
        response.error_code.?,
    );
}

test "rejects a play request with an empty URL" {
    const payload = "{\"command\":\"play\",\"url\":\"\"}";

    try std.testing.expectError(
        extension_protocol.RequestError.EmptyUrl,
        process_json(
            std.testing.allocator,
            payload,
        ),
    );
}

test "valid play-request frame produces a valid response frame" {
    const request_json =
        "{\"command\":\"play\",\"url\":\"https://music.youtube.com/watch?v=example\"}";

    const request_frame = try (native_message.NativeMessage{
        .json_bytes = request_json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(request_frame);

    const response_frame = try process_frame(
        std.testing.allocator,
        request_frame,
    );
    defer std.testing.allocator.free(response_frame);

    const response_message = try native_message.NativeMessage.decode(
        response_frame,
    );

    var parsed_response = try std.json.parseFromSlice(
        extension_protocol.Response,
        std.testing.allocator,
        response_message.json_bytes,
        .{},
    );
    defer parsed_response.deinit();

    try parsed_response.value.validate();

    try std.testing.expectEqual(
        extension_protocol.ResponseStatus.failed,
        parsed_response.value.status,
    );
    try std.testing.expectEqual(
        extension_protocol.ErrorCode.extension_unavailable,
        parsed_response.value.error_code.?,
    );
}

test "rejects a frame shorter than its header" {
    const request_frame = [_]u8{ 0, 0, 0 };

    try std.testing.expectError(
        native_message.NativeMessageError.FrameTooShort,
        process_frame(
            std.testing.allocator,
            &request_frame,
        ),
    );
}

test "rejects a framed play request with an empty URL" {
    const request_json = "{\"command\":\"play\",\"url\":\"\"}";

    const request_frame = try (native_message.NativeMessage{
        .json_bytes = request_json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(request_frame);

    try std.testing.expectError(
        extension_protocol.RequestError.EmptyUrl,
        process_frame(
            std.testing.allocator,
            request_frame,
        ),
    );
}

test "reads a complete native-message frame" {
    const expected_frame = try (native_message.NativeMessage{
        .json_bytes = "{\"command\":\"play\"}",
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(expected_frame);

    var native_reader = std.Io.Reader.fixed(expected_frame);

    const actual_frame = try read_frame(
        std.testing.allocator,
        &native_reader,
    );
    defer std.testing.allocator.free(actual_frame);

    try std.testing.expectEqualSlices(
        u8,
        expected_frame,
        actual_frame,
    );
}

test "rejects a payload larger than the maximum" {
    var header: [@sizeOf(u32)]u8 = undefined;

    std.mem.writeInt(
        u32,
        header[0..],
        @intCast(MAX_PAYLOAD_SIZE + 1),
        .native,
    );

    var native_reader = std.Io.Reader.fixed(&header);

    try std.testing.expectError(
        error.PayloadTooLarge,
        read_frame(std.testing.allocator, &native_reader),
    );
}

test "rejects an incomplete payload stream" {
    var incomplete_frame = [_]u8{ 0, 0, 0, 0, '{', '}' };

    std.mem.writeInt(
        u32,
        incomplete_frame[0..@sizeOf(u32)],
        3,
        .native,
    );

    var native_reader = std.Io.Reader.fixed(&incomplete_frame);

    try std.testing.expectError(
        error.EndOfStream,
        read_frame(std.testing.allocator, &native_reader),
    );
}

test "writes a complete frame" {
    const frame = [_]u8{ 0, 0, 0, 1, 'x' };

    var output_buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try write_frame(&writer, &frame);

    try std.testing.expectEqualSlices(
        u8,
        &frame,
        writer.buffered(),
    );
}

test "returns an error when the output buffer is too small" {
    const frame = [_]u8{ 0, 0, 0, 1, 'x' };

    var output_buffer: [4]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try std.testing.expectError(
        error.WriteFailed,
        write_frame(&writer, &frame),
    );
}

test "runtime socket path prefers XDG_RUNTIME_DIR" {
    const path = try utils.runtime_socket_path(
        std.testing.allocator,
        "/run/user/1000",
        "/tmp/user",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(
        "/run/user/1000/music_hook/host.sock",
        path,
    );
}

test "runtime socket path falls back to TMPDIR" {
    const path = try utils.runtime_socket_path(
        std.testing.allocator,
        null,
        "/tmp/user",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(
        "/tmp/user/music_hook/host.sock",
        path,
    );
}

test "runtime socket path ignores a relative XDG_RUNTIME_DIR" {
    const path = try utils.runtime_socket_path(
        std.testing.allocator,
        "relative/runtime",
        "/tmp/user",
    );
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings(
        "/tmp/user/music_hook/host.sock",
        path,
    );
}

test "runtime socket path rejects missing runtime directories" {
    try std.testing.expectError(
        error.MissingRuntimeDirectory,
        utils.runtime_socket_path(
            std.testing.allocator,
            null,
            null,
        ),
    );
}
