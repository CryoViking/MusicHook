const std = @import("std");

// Emits OSC 8 terminal hyperlinks: visible text which opens a URL when the
// terminal supports hyperlinks. These references describe the convention and
// which terminal emulators implement it:
// - https://iterm2.com/documentation-escape-codes.html#anchor-osc-8
// - https://github.com/Alhadis/OSC8-Adoption

pub const TerminalLinkError = error{
    /// A destination or label attempted to include a terminal control character.
    /// Reject it rather than allowing untrusted text to alter terminal state.
    UnsafeTerminalText,
};

pub fn write(writer: *std.Io.Writer, destination: []const u8, label: []const u8) !void {
    if (!is_safe(destination) or !is_safe(label)) return error.UnsafeTerminalText;

    // OSC (Operating System Command) 8 is the terminal hyperlink convention.
    // Its opening form is: ESC ] 8 ; ; <destination> ESC \\.
    //
    // `\x1b` is the ASCII Escape byte. `]` begins an OSC sequence, `8` selects
    // the hyperlink command, and the two semicolons leave the optional parameter
    // field empty before the URL. ESC followed by `\\` is the String Terminator
    // (ST), which ends the OSC sequence.
    try writer.writeAll("\x1b]8;;");
    try writer.writeAll(destination);
    try writer.writeAll("\x1b\\");

    // The label is the visible text in the terminal. It can be only one wrapped
    // URL fragment while `destination` remains the complete URL, so every
    // fragment can still open the same link.
    try writer.writeAll(label);

    // A second OSC 8 sequence with an empty destination closes the hyperlink:
    // ESC ] 8 ; ; ESC \\. This prevents later terminal output becoming part of it.
    try writer.writeAll("\x1b]8;;\x1b\\");
}

fn is_safe(text: []const u8) bool {
    for (text) |byte| {
        // C0 controls are bytes 0x00 through 0x1f (including Escape, newline,
        // and carriage return). 0x7f is DEL. Any of them could break out of the
        // intended OSC 8 sequence or inject other terminal control commands.
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

test "write emits an OSC 8 hyperlink" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try write(
        &output.writer,
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9",
    );

    try std.testing.expectEqualStrings(
        "\x1b]8;;https://www.youtube.com/watch?v=dQw4w9WgXcQ" ++
            "\x1b\\" ++
            "https://www.youtube.com/watch?v=dQw4w9" ++
            "\x1b]8;;\x1b\\",
        output.writer.buffered(),
    );
}

test "write rejects terminal control characters" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        TerminalLinkError.UnsafeTerminalText,
        write(
            &output.writer,
            "https://example.com/\x1b]malicious",
            "example",
        ),
    );
}
