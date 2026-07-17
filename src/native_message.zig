const std = @import("std");

// Firefox native messaging uses stdin/stdout; every JSON message is UTF-8 bytes
// prefixed by a native-byte-order u32 length. Firefox caps messages sent from
// the host at 1 MB. MDN native messaging
// (https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging)

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
