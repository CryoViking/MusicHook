const std = @import("std");

// Firefox native messaging uses stdin/stdout; every JSON message is UTF-8 bytes
// prefixed by a native-byte-order u32 length. Firefox caps messages sent from
// the host at 1 MB. MDN native messaging
// (https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)

pub const MAX_PAYLOAD_SIZE = 1024 * 1024;

pub const NativeMessageError = error{
    FrameTooShort,
    InvalidPayloadLength,
};

pub const NativeMessage = struct {
    json_bytes: []const u8,

    pub fn encode(
        self: NativeMessage,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const header_size = @sizeOf(u32);
        const frame = try allocator.alloc(
            u8,
            header_size + self.json_bytes.len,
        );
        errdefer allocator.free(frame);

        std.mem.writeInt(
            u32,
            frame[0..header_size],
            @intCast(self.json_bytes.len),
            .native,
        );

        @memcpy(frame[header_size..], self.json_bytes);
        return frame;
    }

    pub fn decode(
        frame: []const u8,
    ) NativeMessageError!NativeMessage {
        const header_size = @sizeOf(u32);
        if (frame.len < header_size) return NativeMessageError.FrameTooShort;

        const declared_lenth: usize = @intCast(
            std.mem.readInt(
                u32,
                frame[0..header_size],
                .native,
            ),
        );

        const payload = frame[header_size..];
        if (declared_lenth != payload.len) return NativeMessageError.InvalidPayloadLength;

        return .{
            .json_bytes = payload,
        };
    }
};

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

test "encodes JSON with a native message header" {
    const json = "{\"command\":\"play\"}";

    const message = NativeMessage{
        .json_bytes = json,
    };

    const frame = try message.encode(std.testing.allocator);
    defer std.testing.allocator.free(frame);

    const header_size = @sizeOf(u32);

    try std.testing.expectEqual(
        @as(u32, @intCast(json.len)),
        std.mem.readInt(
            u32,
            frame[0..header_size],
            .native,
        ),
    );

    try std.testing.expectEqualStrings(
        json,
        frame[header_size..],
    );
}

test "decodes a native message" {
    const json = "{\"command\":\"play\"}";

    const frame = try (NativeMessage{
        .json_bytes = json,
    }).encode(std.testing.allocator);
    defer std.testing.allocator.free(frame);

    const message = try NativeMessage.decode(frame);

    try std.testing.expectEqualStrings(
        json,
        message.json_bytes,
    );
}

test "rejects a frame with an invalid payload length" {
    var frame = [_]u8{ 0, 0, 0, '{', '}' };

    std.mem.writeInt(
        u32,
        frame[0..@sizeOf(u32)],
        3,
        .native,
    );

    try std.testing.expectError(
        NativeMessageError.InvalidPayloadLength,
        NativeMessage.decode(&frame),
    );
}

test "rejects a frame shorter than its header" {
    const frame = [_]u8{ 0, 0, 0 };

    try std.testing.expectError(
        NativeMessageError.FrameTooShort,
        NativeMessage.decode(&frame),
    );
}

test "reads a complete native-message frame" {
    const expected_frame = try (NativeMessage{
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
        read_frame(
            std.testing.allocator,
            &native_reader,
        ),
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
