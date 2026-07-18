const std = @import("std");
const bridge_module = @import("bridge_module");
const native_message = bridge_module.frame;
const extension_protocol = bridge_module.protocol;
const utils_module = @import("utils_module");
const utils = utils_module.utils;

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
        try relay_one(
            allocator,
            &client_reader.interface,
            &client_writer.interface,
            &native_reader.interface,
            &native_writer.interface,
        );
    }
}

fn relay_one(
    allocator: std.mem.Allocator,
    client_reader: *std.Io.Reader,
    client_writer: *std.Io.Writer,
    native_reader: *std.Io.Reader,
    native_writer: *std.Io.Writer,
) !void {
    const request_frame = try native_message.read_frame(
        allocator,
        client_reader,
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

    try parsed_request.value.validate();

    try native_message.write_frame(
        native_writer,
        request_frame,
    );

    const response_frame = try native_message.read_frame(
        allocator,
        native_reader,
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

    try parsed_response.value.validate();

    try native_message.write_frame(
        client_writer,
        response_frame,
    );
}

// SECTION: tests

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
test "relays a play request to the extension and its response to the client" {
    const request_json =
        "{\"command\":\"play\",\"url\":\"https://music.youtube.com/watch?v=example\"}";

    const response_json =
        "{\"status\":\"ok\",\"error_code\":null}";

    const request_frame = try (native_message.NativeMessage{
        .json_bytes = request_json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(request_frame);

    const response_frame = try (native_message.NativeMessage{
        .json_bytes = response_json,
    }).encode(std.testing.allocator);
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

    try std.testing.expectEqualSlices(
        u8,
        request_frame,
        native_writer.buffered(),
    );

    try std.testing.expectEqualSlices(
        u8,
        response_frame,
        client_writer.buffered(),
    );
}
