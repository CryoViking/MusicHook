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
