const std = @import("std");
const bridge_module = @import("bridge_module");
const bridge_frame = bridge_module.frame;
const bridge_protocol = bridge_module.protocol;
const utils_module = @import("utils_module");
const utils = utils_module.utils;
const library_module = @import("library_module");
const target = library_module.target;
const config = library_module.config;
const music_library = library_module.music_library;

pub const FakeHost = struct {
    temp_dir: std.testing.TmpDir,
    runtime_dir: []u8,
    socket_path: []u8,
    listener: std.Io.net.Server,
    response_frame: []u8,
    expected_request: bridge_protocol.Request,
    thread: ?std.Thread = null,
    err: ?anyerror = null,

    pub fn start(
        response_json: []const u8,
        expected_request: bridge_protocol.Request,
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
            .expected_request = expected_request,
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

        const request_message = try bridge_frame.NativeMessage.decode(request_frame);

        var parsed_request = try std.json.parseFromSlice(
            bridge_protocol.Request,
            std.testing.allocator,
            request_message.json_bytes,
            .{},
        );
        defer parsed_request.deinit();

        try parsed_request.value.validate();
        try std.testing.expectEqual(self.expected_request.command, parsed_request.value.command);
        switch (self.expected_request.command) {
            .play => try std.testing.expectEqualStrings(
                self.expected_request.url.?,
                parsed_request.value.url.?,
            ),
            .pause, .@"resume", .ping => try std.testing.expect(parsed_request.value.url == null),
        }

        var output_buffer: [1024]u8 = undefined;
        var writer = client.writer(std.testing.io, &output_buffer);
        try bridge_frame.write_frame(&writer.interface, self.response_frame);
    }
};

pub fn prepare_list_test_library(
    temp_dir: *std.testing.TmpDir,
    targets: []const target.Target,
) ![]u8 {
    var data_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const data_path_length = try temp_dir.dir.realPath(std.testing.io, &data_path_buffer);

    const data_path = try std.testing.allocator.dupe(u8, data_path_buffer[0..data_path_length]);
    defer std.testing.allocator.free(data_path);

    const config_filepath = try std.fs.path.join(std.testing.allocator, &.{ data_path, "config.zon" });

    const cfg = config.Config{ .data_path = data_path };
    try cfg.write_new(
        std.testing.io,
        std.testing.allocator,
        std.Io.Dir.cwd(),
        config_filepath,
    );

    const library = music_library.MusicLibrary{ .targets = targets };
    try library.write_new(
        std.testing.io,
        std.testing.allocator,
        temp_dir.dir,
        "music_library.zon",
    );

    return config_filepath;
}
