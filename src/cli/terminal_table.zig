const std = @import("std");

// NOTE: This might not be best practice, but it gets the job done
// for now. Will address at a later date.
const terminal_link = @import("terminal_link.zig");

// This module separates terminal-table work into two stages:
//
// 1. Compute a stable width for each column from the terminal width available
//    when the table is printed.
// 2. Wrap each cell's text to its assigned width before rendering rows.
//
// The layout is intentionally calculated once. Terminal resize handling would
// require redrawing prior output, which is outside MusicHook's ordinary,
// line-oriented CLI output.
//
// Text is UTF-8. A UTF-8 byte is not necessarily a complete visible character:
// ASCII characters use one byte, while many characters use two to four bytes.
// A Unicode codepoint is the decoded Unicode value represented by one or more
// UTF-8 bytes. The CellLineIterator advances by codepoint so a wrapped slice
// never begins or ends in the middle of a UTF-8 sequence.
//
// For this first implementation, every codepoint consumes one layout unit.
// That is safe for all valid UTF-8 text, but it is an approximation of terminal
// display width: CJK characters and some emoji commonly occupy two terminal
// cells, while combining marks may occupy none. Keeping wrapping behind this
// iterator means we can later improve that measurement without changing table
// layout or row rendering.

pub const LayoutError = error{
    MismatchedColumnCount,
    InvalidColumnWidth,
    NotEnoughWidth,
};

pub const CellError = error{
    ZeroWidth,
    InvalidUtf8,
} || terminal_link.TerminalLinkError;

pub const RowError = error{
    MismatchedCellCount,
    MismatchedScratchCount,
};

pub const Column = struct {
    header: []const u8,
    min_width: usize,
    max_width: usize,
};

pub const WrapMode = enum {
    word,
    character,
};

pub const Cell = struct {
    text: []const u8,
    link_destination: ?[]const u8 = null,
    wrap_mode: WrapMode = .word,
};

pub const CellLineIterator = struct {
    cell: Cell,
    width: usize,
    byte_index: usize,

    pub fn init(cell: Cell, width: usize) CellError!CellLineIterator {
        if (width == 0) return error.ZeroWidth;
        if (!std.unicode.utf8ValidateSlice(cell.text)) return error.InvalidUtf8;

        try terminal_link.validate_text(cell.text);
        if (cell.link_destination) |destination| {
            try terminal_link.validate_text(destination);
        }

        return .{ .cell = cell, .width = width, .byte_index = 0 };
    }

    pub fn next(self: *CellLineIterator) ?[]const u8 {
        return switch (self.cell.wrap_mode) {
            .character => self.next_character_line(),
            .word => self.next_word_line(),
        };
    }

    fn next_character_line(self: *CellLineIterator) ?[]const u8 {
        if (self.byte_index == self.cell.text.len) return null;

        const start = self.byte_index;
        var end = start;
        var used_width: usize = 0;

        while (end < self.cell.text.len and used_width < self.width) {
            end = next_codepoint_end(self.cell.text, end);
            used_width += 1;
        }

        self.byte_index = end;
        return self.cell.text[start..end];
    }

    fn next_word_line(self: *CellLineIterator) ?[]const u8 {
        self.skip_char(' ');
        if (self.byte_index == self.cell.text.len) return null;

        const start = self.byte_index;
        var end = start;
        var used_width: usize = 0;
        var last_space: ?usize = null;

        while (end < self.cell.text.len and used_width < self.width) {
            if (self.cell.text[end] == ' ') last_space = end;

            end = next_codepoint_end(self.cell.text, end);
            used_width += 1;
        }

        if (end == self.cell.text.len) {
            self.byte_index = end;
            return trim_end(self.cell.text[start..end], ' ');
        }

        // The following space is just beyond available width, so the
        // complete word already fits on this line.
        if (self.cell.text[end] == ' ') {
            self.byte_index = end;
            self.skip_char(' ');
            return self.cell.text[start..end];
        }

        if (last_space) |space| {
            // The final character we included was a space; do not render it.
            if (space + 1 == end) {
                self.byte_index = end;
                self.skip_char(' ');
                return self.cell.text[start..space];
            }

            // Wrap before the last whole word that would overflow this line.
            self.byte_index = space;
            self.skip_char(' ');
            return self.cell.text[start..space];
        }

        // One word is wider than the column, so fall back to a hard wrap.
        self.byte_index = end;
        return self.cell.text[start..end];
    }

    fn skip_char(self: *CellLineIterator, c: u8) void {
        while (self.byte_index < self.cell.text.len and
            self.cell.text[self.byte_index] == c)
        {
            self.byte_index += 1;
        }
    }

    fn next_codepoint_end(text: []const u8, start: usize) usize {
        const byte_count = std.unicode.utf8ByteSequenceLength(text[start]) catch unreachable;
        return start + byte_count;
    }

    fn trim_end(text: []const u8, trim_char: u8) []const u8 {
        var end = text.len;
        while (end > 0 and text[end - 1] == trim_char) end -= 1;
        return text[0..end];
    }
};

pub fn write_header(
    writer: *std.Io.Writer,
    columns: []const Column,
    widths: []const usize,
    gap_width: usize,
) !void {
    if (columns.len != widths.len) return error.MismatchedColumnCount;

    for (columns, widths, 0..) |column, width, idx| {
        if (!std.unicode.utf8ValidateSlice(column.header)) return error.InvalidUtf8;

        try terminal_link.validate_text(column.header);

        const header_width = codepoint_count(column.header);
        if (header_width > width) return error.HeaderTooWide;

        try writer.writeAll(column.header);
        try repeat_write_char(writer, ' ', width - header_width);

        if (idx + 1 < columns.len) try repeat_write_char(
            writer,
            ' ',
            gap_width,
        );
    }

    try writer.writeByte('\n');
}

pub fn write_separator(
    writer: *std.Io.Writer,
    widths: []const usize,
    gap_width: usize,
) !void {
    for (widths, 0..) |width, idx| {
        for (0..width) |_| {
            try writer.writeAll("─");
        }
        if (idx + 1 < widths.len) try repeat_write_char(writer, ' ', gap_width);
    }
    try writer.writeByte('\n');
}

pub fn write_row(
    writer: *std.Io.Writer,
    cells: []const Cell,
    widths: []const usize,
    gap_width: usize,
    iterators: []CellLineIterator,
    fragments: []?[]const u8,
) !void {
    if (cells.len != widths.len) return error.MismatchedCellCount;
    if (iterators.len != cells.len or fragments.len != cells.len)
        return error.MismatchedScratchCount;

    for (cells, widths, 0..) |cell, width, idx| {
        iterators[idx] = try CellLineIterator.init(cell, width);
    }

    while (true) {
        var has_fragment = false;

        for (iterators, 0..) |*iterator, idx| {
            fragments[idx] = iterator.next();
            if (fragments[idx] != null) has_fragment = true;
        }

        if (!has_fragment) break;

        for (cells, widths, fragments, 0..) |
            cell,
            width,
            fragment,
            idx,
        | {
            if (fragment) |text| {
                if (cell.link_destination) |destination| {
                    try terminal_link.write(
                        writer,
                        destination,
                        text,
                    );
                } else try writer.writeAll(text);

                try repeat_write_char(
                    writer,
                    ' ',
                    width - codepoint_count(text),
                );
            } else try repeat_write_char(writer, ' ', width);

            if (idx + 1 < cells.len) try repeat_write_char(
                writer,
                ' ',
                gap_width,
            );
        }

        try writer.writeByte('\n');
    }
}

fn codepoint_count(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch unreachable;
}

fn repeat_write_char(writer: *std.Io.Writer, c: u8, count: usize) !void {
    for (0..count) |_| {
        try writer.writeByte(c);
    }
}

pub fn compute_column_widths(
    columns: []const Column,
    gap_width: usize,
    available_width: usize,
    widths: []usize,
) LayoutError!void {
    if (widths.len != columns.len) return error.MismatchedColumnCount;

    for (columns) |col| {
        if (col.min_width > col.max_width) return error.InvalidColumnWidth;
    }

    var table_min_width: usize = 0;
    for (columns, 0..) |col, idx| {
        widths[idx] = col.min_width;
        table_min_width += col.min_width;
    }
    if (columns.len > 1) table_min_width += (columns.len - 1) * gap_width;
    if (available_width < table_min_width) return error.NotEnoughWidth;

    var remaining_width = available_width - table_min_width;

    while (remaining_width > 0) {
        var grew_a_column = false;

        for (columns, 0..) |col, idx| {
            if (widths[idx] == col.max_width) continue;

            widths[idx] += 1;
            remaining_width -= 1;
            grew_a_column = true;

            if (remaining_width == 0) break;
        }

        if (!grew_a_column) break;
    }
}

test "uses minimum widths when the table exactly fits" {
    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 8, .max_width = 12 },
        .{ .header = "TITLE", .min_width = 12, .max_width = 20 },
        .{ .header = "URL", .min_width = 24, .max_width = 48 },
    };
    var widths: [columns.len]usize = undefined;

    try compute_column_widths(
        &columns,
        2,
        48,
        &widths,
    );

    try std.testing.expectEqualSlices(usize, &.{ 8, 12, 24 }, &widths);
}

test "shares spare width between uncapped columns" {
    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 8, .max_width = 12 },
        .{ .header = "TITLE", .min_width = 12, .max_width = 20 },
        .{ .header = "URL", .min_width = 24, .max_width = 48 },
    };
    var widths: [columns.len]usize = undefined;

    try compute_column_widths(
        &columns,
        2,
        54,
        &widths,
    );

    try std.testing.expectEqualSlices(usize, &.{ 10, 14, 26 }, &widths);
}

test "continues giving width to columns that have not reached their maximum" {
    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 8, .max_width = 9 },
        .{ .header = "TITLE", .min_width = 12, .max_width = 13 },
        .{ .header = "URL", .min_width = 24, .max_width = 64 },
    };
    var widths: [columns.len]usize = undefined;

    try compute_column_widths(
        &columns,
        2,
        58,
        &widths,
    );

    try std.testing.expectEqualSlices(usize, &.{ 9, 13, 32 }, &widths);
}

test "rejects an available width smaller than the minimum table width" {
    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 8, .max_width = 12 },
        .{ .header = "TITLE", .min_width = 12, .max_width = 20 },
        .{ .header = "URL", .min_width = 24, .max_width = 48 },
    };
    var widths: [columns.len]usize = undefined;

    try std.testing.expectError(
        error.NotEnoughWidth,
        compute_column_widths(
            &columns,
            2,
            47,
            &widths,
        ),
    );
}

test "rejects an output slice with the wrong number of widths" {
    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 8, .max_width = 12 },
        .{ .header = "URL", .min_width = 24, .max_width = 48 },
    };
    var widths: [1]usize = undefined;

    try std.testing.expectError(
        error.MismatchedColumnCount,
        compute_column_widths(
            &columns,
            2,
            40,
            &widths,
        ),
    );
}

test "rejects a column whose minimum exceeds its maximum" {
    const columns = [_]Column{
        .{ .header = "TITLE", .min_width = 20, .max_width = 12 },
    };
    var widths: [columns.len]usize = undefined;

    try std.testing.expectError(
        error.InvalidColumnWidth,
        compute_column_widths(
            &columns,
            2,
            30,
            &widths,
        ),
    );
}

test "a short cell yields its complete text once" {
    var iterator = try CellLineIterator.init(
        .{ .text = "Dusk Focus" },
        20,
    );

    try std.testing.expectEqualStrings("Dusk Focus", iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "character wrapping splits text at the configured width" {
    var iterator = try CellLineIterator.init(
        .{ .text = "abcdefgh", .wrap_mode = .character },
        3,
    );

    try std.testing.expectEqualStrings("abc", iterator.next().?);
    try std.testing.expectEqualStrings("def", iterator.next().?);
    try std.testing.expectEqualStrings("gh", iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "word wrapping keeps a word together when it fits" {
    var iterator = try CellLineIterator.init(
        .{ .text = "Dusk Focus Mix" },
        10,
    );

    try std.testing.expectEqualStrings("Dusk Focus", iterator.next().?);
    try std.testing.expectEqualStrings("Mix", iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "word wrapping falls back to a hard wrap for a long word" {
    var iterator = try CellLineIterator.init(
        .{ .text = "abcdefgh" },
        3,
    );

    try std.testing.expectEqualStrings("abc", iterator.next().?);
    try std.testing.expectEqualStrings("def", iterator.next().?);
    try std.testing.expectEqualStrings("gh", iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "cell line iterator rejects zero width" {
    try std.testing.expectError(
        error.ZeroWidth,
        CellLineIterator.init(.{ .text = "Dusk Focus" }, 0),
    );
}

test "cell line iterator rejects invalid UTF-8" {
    try std.testing.expectError(
        error.InvalidUtf8,
        CellLineIterator.init(
            .{ .text = "\xff" },
            10,
        ),
    );
}

test "character wrapping does not split UTF-8 codepoints" {
    var iterator = try CellLineIterator.init(
        .{ .text = "多巴胺核爆", .wrap_mode = .character },
        2,
    );

    const first = iterator.next().?;
    const second = iterator.next().?;
    const third = iterator.next().?;

    try std.testing.expectEqualStrings("多巴", first);
    try std.testing.expectEqualStrings("胺核", second);
    try std.testing.expectEqualStrings("爆", third);

    try std.testing.expect(std.unicode.utf8ValidateSlice(first));
    try std.testing.expect(std.unicode.utf8ValidateSlice(second));
    try std.testing.expect(std.unicode.utf8ValidateSlice(third));
    try std.testing.expect(iterator.next() == null);
}

test "cell line iterator rejects terminal control characters in text" {
    try std.testing.expectError(
        error.UnsafeTerminalText,
        CellLineIterator.init(
            .{ .text = "Dusk\nFocus" },
            10,
        ),
    );
}

test "cell line iterator rejects terminal control characters in link destinations" {
    try std.testing.expectError(
        error.UnsafeTerminalText,
        CellLineIterator.init(
            .{
                .text = "Example",
                .link_destination = "https://example.com/\x1b]malicious",
            },
            10,
        ),
    );
}

test "write_row aligns continuation lines beneath their columns" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const cells = [_]Cell{
        .{ .text = "dusk" },
        .{ .text = "Dusk Focus" },
        .{
            .text = "abcdefgh",
            .wrap_mode = .character,
        },
    };
    const widths = [_]usize{ 8, 10, 4 };

    var iterators: [cells.len]CellLineIterator = undefined;
    var fragments: [cells.len]?[]const u8 = undefined;

    try write_row(
        &output.writer,
        &cells,
        &widths,
        2,
        &iterators,
        &fragments,
    );

    try std.testing.expectEqualStrings(
        "dusk      Dusk Focus  abcd\n" ++
            "                      efgh\n",
        output.writer.buffered(),
    );
}

test "write_row makes every wrapped link fragment point to its full destination" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const destination = "https://example.com/abcdefgh";
    const cells = [_]Cell{
        .{
            .text = "abcdefgh",
            .link_destination = destination,
            .wrap_mode = .character,
        },
    };
    const widths = [_]usize{2};

    var iterators: [cells.len]CellLineIterator = undefined;
    var fragments: [cells.len]?[]const u8 = undefined;

    try write_row(
        &output.writer,
        &cells,
        &widths,
        2,
        &iterators,
        &fragments,
    );

    try std.testing.expectEqualStrings(
        "\x1b]8;;https://example.com/abcdefgh\x1b\\ab\x1b]8;;\x1b\\\n" ++
            "\x1b]8;;https://example.com/abcdefgh\x1b\\cd\x1b]8;;\x1b\\\n" ++
            "\x1b]8;;https://example.com/abcdefgh\x1b\\ef\x1b]8;;\x1b\\\n" ++
            "\x1b]8;;https://example.com/abcdefgh\x1b\\gh\x1b]8;;\x1b\\\n",
        output.writer.buffered(),
    );
}

test "write_row rejects mismatched cells and widths" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const cells = [_]Cell{
        .{ .text = "dusk" },
    };
    const widths = [_]usize{ 8, 12 };

    var iterators: [cells.len]CellLineIterator = undefined;
    var fragments: [cells.len]?[]const u8 = undefined;

    try std.testing.expectError(
        error.MismatchedCellCount,
        write_row(
            &output.writer,
            &cells,
            &widths,
            2,
            &iterators,
            &fragments,
        ),
    );
}

test "write_header and separator use the column layout" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 8, .max_width = 12 },
        .{ .header = "TITLE", .min_width = 10, .max_width = 20 },
        .{ .header = "URL", .min_width = 4, .max_width = 48 },
    };
    const widths = [_]usize{ 8, 10, 4 };

    try write_header(&output.writer, &columns, &widths, 2);
    try write_separator(&output.writer, &widths, 2);

    try std.testing.expectEqualStrings(
        "ALIAS     TITLE       URL \n" ++
            "────────  ──────────  ────\n",
        output.writer.buffered(),
    );
}

test "write_header rejects mismatched columns and widths" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 8, .max_width = 12 },
    };
    const widths = [_]usize{};

    try std.testing.expectError(
        error.MismatchedColumnCount,
        write_header(
            &output.writer,
            &columns,
            &widths,
            2,
        ),
    );
}

test "write_header rejects a header wider than its column" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const columns = [_]Column{
        .{ .header = "ALIAS", .min_width = 4, .max_width = 8 },
    };
    const widths = [_]usize{4};

    try std.testing.expectError(
        error.HeaderTooWide,
        write_header(
            &output.writer,
            &columns,
            &widths,
            2,
        ),
    );
}

test "write_header rejects terminal control characters" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    const columns = [_]Column{
        .{ .header = "ALIAS\n", .min_width = 8, .max_width = 12 },
    };
    const widths = [_]usize{8};

    try std.testing.expectError(
        error.UnsafeTerminalText,
        write_header(
            &output.writer,
            &columns,
            &widths,
            2,
        ),
    );
}
