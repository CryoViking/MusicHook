const std = @import("std");
const library_module = @import("library_module");
const target = library_module.target;

// 4mb max response
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

pub const ResolveError = error{
    UnsupportedUrl,
    MissingTitle,
    UnexpectedResponseStatus,
    ResponseTooLarge,
};

pub const ResolvedTarget = struct {
    target: target.Target,

    pub fn deinit(self: ResolvedTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.target.title);
    }
};

pub fn resolve(
    io: std.Io,
    allocator: std.mem.Allocator,
    alias: []const u8,
    url: []const u8,
) !ResolvedTarget {
    const response_buffer = try allocator.alloc(u8, MAX_RESPONSE_BYTES);
    defer allocator.free(response_buffer);

    var response_writer = std.Io.Writer.fixed(response_buffer);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const response = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_writer,
        .headers = .{
            .user_agent = .{
                .override = "MusicHook/0.1",
            },
        },
    }) catch |err| switch (err) {
        error.WriteFailed => return error.ResponseTooLarge,
        else => |other| return other,
    };

    if (response.status != .ok) return error.UnexpectedResponseStatus;

    return resolve_from_html(
        allocator,
        alias,
        url,
        response_writer.buffered(),
    );
}

pub fn resolve_from_html(
    allocator: std.mem.Allocator,
    alias: []const u8,
    url: []const u8,
    html: []const u8,
) !ResolvedTarget {
    const source = try source_from_url(url);
    const kind = try kind_from_url(url);
    const title = try extract_title(html);

    const owned_title = try allocator.dupe(u8, title);

    return .{
        .target = .{
            .alias = alias,
            .title = owned_title,
            .kind = kind,
            .source = source,
            .url = url,
        },
    };
}

pub fn source_from_url(url: []const u8) ResolveError!target.TargetSource {
    const uri = std.Uri.parse(url) catch {
        return error.UnsupportedUrl;
    };

    if (!std.mem.eql(u8, uri.scheme, "https")) return error.UnsupportedUrl;

    const host = uri.host orelse return error.UnsupportedUrl;
    const domain = host.percent_encoded;

    if (std.mem.eql(u8, domain, "music.youtube.com")) return .ytmusic;

    if (std.mem.eql(u8, domain, "youtube.com") or
        std.mem.eql(u8, domain, "www.youtube.com"))
    {
        return .youtube;
    }

    return error.UnsupportedUrl;
}

pub fn kind_from_url(url: []const u8) ResolveError!target.TargetKind {
    const uri = std.Uri.parse(url) catch {
        return error.UnsupportedUrl;
    };

    // We need kind_from_url to reject non-YouTube URLs too,
    // but we do not need its returned source value here.
    // So perform th eexpression and intentially discard its
    // value.
    _ = try source_from_url(url);

    if (std.mem.eql(u8, uri.path.percent_encoded, "/playlist")) {
        return .playlist;
    }

    if (std.mem.eql(u8, uri.path.percent_encoded, "/watch")) {
        return .track;
    }

    return error.UnsupportedUrl;
}

pub fn extract_title(html: []const u8) ResolveError![]const u8 {
    const marker = "<meta property=\"og:title\" content=\"";

    const title_start = std.mem.indexOf(u8, html, marker) orelse
        return error.MissingTitle;

    const content_start = title_start + marker.len;
    const content_end = std.mem.indexOfPos(
        u8,
        html,
        content_start,
        "\"",
    ) orelse return error.MissingTitle;

    const title = html[content_start..content_end];
    if (title.len == 0) return error.MissingTitle;
    return title;
}

test "source_from_url recognises YouTube Music" {
    const source = try source_from_url(
        "https://music.youtube.com/watch?v=example",
    );

    try std.testing.expectEqual(target.TargetSource.ytmusic, source);
}

test "source_from_url recognises standard YouTube domains" {
    const urls = [_][]const u8{
        "https://youtube.com/watch?v=example",
        "https://www.youtube.com/watch?v=example",
    };

    for (urls) |url| {
        const source = try source_from_url(url);
        try std.testing.expectEqual(target.TargetSource.youtube, source);
    }
}

test "source_from_url rejects an unsupported URL" {
    try std.testing.expectError(
        ResolveError.UnsupportedUrl,
        source_from_url("https://example.com/watch?v=example"),
    );
}

test "kind_from_url recognises a playlist URL" {
    const kind = try kind_from_url(
        "https://music.youtube.com/playlist?list=example",
    );

    try std.testing.expectEqual(target.TargetKind.playlist, kind);
}

test "kind_from_url recognises a watch URL as a track" {
    const kind = try kind_from_url(
        "https://www.youtube.com/watch?v=example",
    );

    try std.testing.expectEqual(target.TargetKind.track, kind);
}

test "extract_title reads an Open Graph title" {
    const html =
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <meta property="og:title" content="Dusk Focus">
        \\  </head>
        \\</html>
    ;

    const title = try extract_title(html);
    try std.testing.expectEqualStrings("Dusk Focus", title);
}

test "extract_title rejects missing Open Graph title" {
    const html =
        \\<!doctype html>
        \\<html>
        \\  <head></head>
        \\</html>
    ;

    try std.testing.expectError(ResolveError.MissingTitle, extract_title(html));
}

test "resolve_from_html builds a YouTube Music target" {
    const url = "https://music.youtube.com/watch?v=example";
    const html =
        \\<meta property="og:title" content="Best Nightcore Mix 2025 🎧 Best Nightcore Songs Mix 🎧 New Music 2025 EDM Gaming Music">
    ;

    const resolved = try resolve_from_html(
        std.testing.allocator,
        "nightcore",
        url,
        html,
    );
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("nightcore", resolved.target.alias);
    try std.testing.expectEqualStrings(
        "Best Nightcore Mix 2025 🎧 Best Nightcore Songs Mix 🎧 New Music 2025 EDM Gaming Music",
        resolved.target.title,
    );
    try std.testing.expectEqual(
        target.TargetSource.ytmusic,
        resolved.target.source,
    );
    try std.testing.expectEqual(target.TargetKind.track, resolved.target.kind);
    try std.testing.expectEqualStrings(url, resolved.target.url);
}
