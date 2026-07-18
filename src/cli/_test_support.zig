const std = @import("std");
const bridge_module = @import("bridge_module");
const bridge_frame = bridge_module.frame;
const bridge_protocol = bridge_module.protocol;
const utils_module = @import("utils_module");
const utils = utils_module.utils;

pub const FakeHost = struct {
    temp_dir: std.testing.TmpDir,
    runtime_dir: []u8,
    socket_path: []u8,
    listener: std.Io.net.Server,
    response_frame: []u8,
    expected_url: []const u8,
    thread: ?std.Thread = null,
    err: ?anyerror = null,

    pub fn start(
        response_json: []const u8,
        expected_url: []const u8,
    ) !*FakeHost {
        var temp_dir = std.testing.tmpDir(.{});
        errdefer temp_dir.cleanup();

        var runtime_dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const runtime_dir_length = try temp_dir.dir.realPath(
            std.testing.io,
            &runtime_dir_buffer,
        );
        const runtime_dir = try std.testing.allocator.dupe(
            u8,
            runtime_dir_buffer[0..runtime_dir_length],
        );
        errdefer std.testing.allocator.free(runtime_dir);

        var socket_dir = try temp_dir.dir.createDirPathOpen(
            std.testing.io,
            "music_hook",
            .{
                .permissions = .fromMode(0o700),
            },
        );
        socket_dir.close(std.testing.io);

        const socket_path = try utils.runtime_socket_path(
            std.testing.allocator,
            null,
            runtime_dir,
        );
        errdefer std.testing.allocator.free(socket_path);

        const socket_address = try std.Io.net.UnixAddress.init(socket_path);

        var listener = try socket_address.listen(std.testing.io, .{});
        errdefer {
            listener.deinit(std.testing.io);
            std.Io.Dir.deleteFileAbsolute(
                std.testing.io,
                socket_path,
            ) catch {};
        }

        const response_frame = try (bridge_frame.NativeMessage{
            .json_bytes = response_json,
        }).encode(std.testing.allocator);
        errdefer std.testing.allocator.free(response_frame);

        const self = try std.testing.allocator.create(FakeHost);
        errdefer std.testing.allocator.destroy(self);

        self.* = .{
            .temp_dir = temp_dir,
            .runtime_dir = runtime_dir,
            .socket_path = socket_path,
            .listener = listener,
            .response_frame = response_frame,
            .expected_url = expected_url,
        };

        self.thread = try std.Thread.spawn(
            .{},
            FakeHost.run,
            .{self},
        );

        return self;
    }

    pub fn join(self: *FakeHost) !void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (self.err) |err| return err;
    }

    pub fn deinit(self: *FakeHost) void {
        self.listener.deinit(std.testing.io);

        if (self.thread) |thread| {
            thread.join();
        }

        std.Io.Dir.deleteFileAbsolute(
            std.testing.io,
            self.socket_path,
        ) catch {};

        std.testing.allocator.free(self.response_frame);
        std.testing.allocator.free(self.socket_path);
        std.testing.allocator.free(self.runtime_dir);
        self.temp_dir.cleanup();
        std.testing.allocator.destroy(self);
    }

    fn run(self: *FakeHost) void {
        self.serve() catch |err| {
            self.err = err;
        };
    }

    fn serve(self: *FakeHost) !void {
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
            self.expected_url,
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
