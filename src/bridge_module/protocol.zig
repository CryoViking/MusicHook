const std = @import("std");

pub const Command = enum {
    play,
    pause,
    @"resume",
    ping,
};

//   Get the specified package
pub const RequestError = error{
    MissingUrl,
    EmptyUrl,
    UnexpectedUrl,
};

pub const Request = struct {
    command: Command,
    url: ?[]const u8 = null,

    pub fn validate(self: Request) RequestError!void {
        switch (self.command) {
            .play => {
                const url = self.url orelse return error.MissingUrl;
                if (url.len == 0) return RequestError.EmptyUrl;
            },
            .pause, .@"resume", .ping => {
                if (self.url != null) return error.UnexpectedUrl;
            },
        }
    }
};

pub const ResponseStatus = enum {
    ok,
    failed,
};

pub const ErrorCode = enum {
    extension_unavailable,
    zen_unavailable,
    playback_failed,
};

pub const ResponseError = error{
    MissingErrorCode,
    UnexpectedErrorCode,
};

pub const Response = struct {
    status: ResponseStatus,
    error_code: ?ErrorCode = null,

    pub fn validate(self: Response) ResponseError!void {
        switch (self.status) {
            .ok => if (self.error_code != null) {
                return ResponseError.UnexpectedErrorCode;
            },
            .failed => if (self.error_code == null) {
                return ResponseError.MissingErrorCode;
            },
        }
    }
};

test "play request accepts a URL" {
    const request = Request{ .command = .play, .url = "https://music.youtube.com/watch?v=example" };
    try request.validate();
}

test "play request rejects a missing URL" {
    const request = Request{ .command = .play };
    try std.testing.expectError(RequestError.MissingUrl, request.validate());
}

test "play request rejects an empty URL" {
    const request = Request{ .command = .play, .url = "" };
    try std.testing.expectError(RequestError.EmptyUrl, request.validate());
}

test "pause request accepts no URL" {
    const request = Request{ .command = .pause };
    try request.validate();
}

test "resume request accepts no URL" {
    const request = Request{ .command = .@"resume" };
    try request.validate();
}

test "pause request rejects a URL" {
    const request = Request{ .command = .pause, .url = "https://music.youtube.com/watch?v=example" };
    try std.testing.expectError(RequestError.UnexpectedUrl, request.validate());
}

test "resume request rejects a URL" {
    const request = Request{ .command = .@"resume", .url = "https://music.youtube.com/watch?v=example" };
    try std.testing.expectError(RequestError.UnexpectedUrl, request.validate());
}
test "failed response requires an error code" {
    const response = Response{ .status = .failed };
    try std.testing.expectError(ResponseError.MissingErrorCode, response.validate());
}

test ".ok response containing an error_code must return UnexpectedErrorCode" {
    const response = Response{
        .status = .ok,
        .error_code = .extension_unavailable,
    };

    try std.testing.expectError(
        ResponseError.UnexpectedErrorCode,
        response.validate(),
    );
}

test "play request encodes as JSON" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const request = Request{
        .command = .play,
        .url = "https://music.youtube.com/watch?v=example",
    };

    try std.json.Stringify.value(request, .{}, &output.writer);
    try std.testing.expectEqualStrings(
        "{\"command\":\"play\",\"url\":\"https://music.youtube.com/watch?v=example\"}",
        output.written(),
    );
}

test "JSON Request decodes successfully" {
    const expected_request = Request{ .command = .play, .url = "https://music.youtube.com/watch?v=example" };
    const payload = "{\"command\":\"play\",\"url\":\"https://music.youtube.com/watch?v=example\"}";

    const actual_request = try std.json.parseFromSlice(
        Request,
        std.testing.allocator,
        payload,
        .{},
    );
    defer actual_request.deinit();

    try std.testing.expectEqual(expected_request.command, actual_request.value.command);
    try std.testing.expectEqualStrings(expected_request.url.?, actual_request.value.url.?);
}

test "encodes and decodes an ok response" {
    const response = Response{ .status = .ok };
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try std.json.Stringify.value(response, .{}, &output.writer);

    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"error_code\":null}", output.written());

    var parsed = try std.json.parseFromSlice(
        Response,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();

    try parsed.value.validate();
    try std.testing.expectEqual(response.status, parsed.value.status);
    try std.testing.expectEqual(response.error_code, parsed.value.error_code);
}

test "encodes and decodes a failed response" {
    const response = Response{
        .status = .failed,
        .error_code = .zen_unavailable,
    };

    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try std.json.Stringify.value(response, .{}, &output.writer);

    try std.testing.expectEqualStrings(
        "{\"status\":\"failed\",\"error_code\":\"zen_unavailable\"}",
        output.written(),
    );

    var parsed = try std.json.parseFromSlice(
        Response,
        std.testing.allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();

    try parsed.value.validate();
    try std.testing.expectEqual(response.status, parsed.value.status);
    try std.testing.expectEqual(response.error_code, parsed.value.error_code);
}

test "pause request encodes as JSON" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const request = Request{ .command = .pause };

    try std.json.Stringify.value(request, .{}, &output.writer);
    try std.testing.expectEqualStrings("{\"command\":\"pause\",\"url\":null}", output.written());
}

test "JSON pause Request decodes successfully" {
    const payload = "{\"command\":\"pause\",\"url\":null}";

    const request = try std.json.parseFromSlice(
        Request,
        std.testing.allocator,
        payload,
        .{},
    );
    defer request.deinit();

    try std.testing.expectEqual(Command.pause, request.value.command);
    try std.testing.expect(request.value.url == null);
    try request.value.validate();
}

test "ping request accepts no URL" {
    const request = Request{ .command = .ping };
    try request.validate();
}

test "ping request rejects a URL" {
    const request = Request{ .command = .ping, .url = "https://music.youtube.com/watch?v=example" };

    try std.testing.expectError(
        RequestError.UnexpectedUrl,
        request.validate(),
    );
}

test "ping request encodes as JSON" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try std.json.Stringify.value(Request{ .command = .ping }, .{}, &output.writer);
    try std.testing.expectEqualStrings("{\"command\":\"ping\",\"url\":null}", output.written());
}
