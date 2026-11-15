//! A small RFC 4180 CSV reader over a byte slice.
//!
//! This is the one place the project parses a format by hand instead of using
//! a library (docs/decisions/0007, decision 4): no maintained Zig CSV library
//! exists, and the format is tiny and stable. It is strict and bounded:
//!   * fields may be quoted; inside quotes `""` is a quote and line breaks are
//!     data; a quote inside an unquoted field is an error;
//!   * rows end in LF or CRLF (a bare CR is an error); the last row may lack
//!     its line break; completely empty lines are skipped;
//!   * a leading UTF-8 byte order mark is ignored;
//!   * field size and field count are limited, so hostile input cannot make a
//!     single row consume unbounded memory;
//!   * rows may have different numbers of fields; callers decide what that means.
//! The reader never copies the whole input; fields without escapes are slices
//! of it.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Unterminated quote, text after a closing quote, quote inside an
    /// unquoted field, or a bare carriage return.
    Malformed,
    FieldTooLarge,
    TooManyFields,
    OutOfMemory,
};

pub const Limits = struct {
    max_field_bytes: usize = 1 << 20,
    max_fields: usize = 256,
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    limits: Limits = .{},

    pub fn init(data: []const u8, limits: Limits) Reader {
        const bom = "\xEF\xBB\xBF";
        const start: usize = if (std.mem.startsWith(u8, data, bom)) bom.len else 0;
        return .{ .data = data, .pos = start, .limits = limits };
    }

    /// The next row, or null at the end. The returned slice and any
    /// unescaped field memory live in `arena`/the input; call with an arena
    /// you reset between rows to keep memory flat.
    pub fn next(self: *Reader, arena: Allocator) Error!?[]const []const u8 {
        // Skip empty lines.
        while (self.pos < self.data.len) {
            if (self.data[self.pos] == '\n') {
                self.pos += 1;
            } else if (self.data[self.pos] == '\r' and self.pos + 1 < self.data.len and self.data[self.pos + 1] == '\n') {
                self.pos += 2;
            } else break;
        }
        if (self.pos >= self.data.len) return null;

        var fields: std.ArrayList([]const u8) = .empty;
        while (true) {
            if (fields.items.len >= self.limits.max_fields) return error.TooManyFields;
            try fields.append(arena, try self.field(arena));
            // field() stops on ',', a line break, or the end.
            if (self.pos >= self.data.len) break;
            const c = self.data[self.pos];
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c == '\n') {
                self.pos += 1;
                break;
            }
            // '\r' (field() has verified it starts a CRLF)
            self.pos += 2;
            break;
        }
        return fields.items;
    }

    fn field(self: *Reader, arena: Allocator) Error![]const u8 {
        const d = self.data;
        if (self.pos < d.len and d[self.pos] == '"') return self.quoted(arena);

        const start = self.pos;
        while (self.pos < d.len) : (self.pos += 1) {
            switch (d[self.pos]) {
                ',', '\n' => break,
                '\r' => {
                    if (self.pos + 1 < d.len and d[self.pos + 1] == '\n') break;
                    return error.Malformed;
                },
                '"' => return error.Malformed,
                else => {},
            }
        }
        if (self.pos - start > self.limits.max_field_bytes) return error.FieldTooLarge;
        return d[start..self.pos];
    }

    fn quoted(self: *Reader, arena: Allocator) Error![]const u8 {
        const d = self.data;
        self.pos += 1; // opening quote
        const start = self.pos;
        var out: ?std.ArrayList(u8) = null; // only built if the field has `""`
        var seg = start;
        while (true) {
            const q = std.mem.indexOfScalarPos(u8, d, self.pos, '"') orelse return error.Malformed;
            if (q - start > self.limits.max_field_bytes) return error.FieldTooLarge;
            if (q + 1 < d.len and d[q + 1] == '"') {
                if (out == null) out = .empty;
                try out.?.appendSlice(arena, d[seg..q]);
                try out.?.append(arena, '"');
                if (out.?.items.len > self.limits.max_field_bytes) return error.FieldTooLarge;
                self.pos = q + 2;
                seg = self.pos;
                continue;
            }
            // closing quote
            self.pos = q + 1;
            if (self.pos < d.len) {
                const c = d[self.pos];
                const ok = c == ',' or c == '\n' or (c == '\r' and self.pos + 1 < d.len and d[self.pos + 1] == '\n');
                if (!ok) return error.Malformed;
            }
            if (out) |*o| {
                try o.appendSlice(arena, d[seg..q]);
                if (o.items.len > self.limits.max_field_bytes) return error.FieldTooLarge;
                return o.items;
            }
            return d[start..q];
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRows(input: []const u8, expected: []const []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r = Reader.init(input, .{});
    for (expected) |row| {
        const got = (try r.next(arena.allocator())) orelse return error.TestUnexpectedEnd;
        try testing.expectEqual(row.len, got.len);
        for (row, got) |e, g| try testing.expectEqualStrings(e, g);
    }
    try testing.expect((try r.next(arena.allocator())) == null);
}

test "plain rows, LF and CRLF, with and without a final line break" {
    try expectRows("a,b,c\n1,2,3\n", &.{ &.{ "a", "b", "c" }, &.{ "1", "2", "3" } });
    try expectRows("a,b\r\n1,2\r\n", &.{ &.{ "a", "b" }, &.{ "1", "2" } });
    try expectRows("a,b\n1,2", &.{ &.{ "a", "b" }, &.{ "1", "2" } });
    try expectRows("a\r\n\r\n\nb", &.{ &.{"a"}, &.{"b"} }); // empty lines skipped
    try expectRows("", &.{});
}

test "empty fields, including a trailing comma" {
    try expectRows("a,,c\n,\n", &.{ &.{ "a", "", "c" }, &.{ "", "" } });
    try expectRows("a,b,\n", &.{&.{ "a", "b", "" }});
    try expectRows("x,\"\"\n", &.{&.{ "x", "" }});
}

test "quoted fields: commas, doubled quotes and line breaks are data" {
    try expectRows("\"a,b\",\"say \"\"hi\"\"\",\"line1\nline2\"\n", &.{&.{ "a,b", "say \"hi\"", "line1\nline2" }});
    try expectRows("\"x\r\ny\",z\r\n", &.{&.{ "x\r\ny", "z" }});
    try expectRows("\"\"\"\"\n", &.{&.{"\""}}); // a field that is one quote
}

test "a byte order mark at the start is ignored" {
    try expectRows("\xEF\xBB\xBFa,b\n", &.{&.{ "a", "b" }});
}

test "non-ASCII text passes through unchanged" {
    try expectRows("café,\"ünï\"\n", &.{&.{ "café", "ünï" }});
}

test "malformed input is an error, never silently repaired" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "\"unterminated",
        "\"a\"b,c\n", // text after the closing quote
        "ab\"c,d\n", // quote inside an unquoted field
        "a\rb\n", // bare CR
        "a,\"b\"\"", // quote opened by escape, never closed
    };
    for (bad) |input| {
        var r = Reader.init(input, .{});
        try testing.expectError(error.Malformed, r.next(arena.allocator()));
    }
}

test "limits bound a single field and a single row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var r = Reader.init("abcdefgh,x\n", .{ .max_field_bytes = 4 });
    try testing.expectError(error.FieldTooLarge, r.next(arena.allocator()));
    var r2 = Reader.init("\"abcdefgh\",x\n", .{ .max_field_bytes = 4 });
    try testing.expectError(error.FieldTooLarge, r2.next(arena.allocator()));
    var r3 = Reader.init("a,b,c,d\n", .{ .max_fields = 3 });
    try testing.expectError(error.TooManyFields, r3.next(arena.allocator()));
}

test "rows with different field counts are returned as they are" {
    try expectRows("a,b,c\nd\n", &.{ &.{ "a", "b", "c" }, &.{"d"} });
}

test "fields without escapes point into the input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "plain,\"quoted\"\n";
    var r = Reader.init(input, .{});
    const row = (try r.next(arena.allocator())).?;
    try testing.expect(row[0].ptr == input.ptr);
    try testing.expect(row[1].ptr == input.ptr + 7);
}

test "random input never crashes the reader and respects its limits" {
    var prng = std.Random.DefaultPrng.init(0xc5f1);
    const rnd = prng.random();
    const alphabet = "ab,\"\r\n \xef\xbb\xbf\x00";
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (0..4000) |_| {
        _ = arena_state.reset(.retain_capacity);
        var buf: [160]u8 = undefined;
        const len = rnd.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        var r = Reader.init(buf[0..len], .{ .max_field_bytes = 20, .max_fields = 6 });
        var rows: usize = 0;
        while (r.next(arena_state.allocator())) |maybe| {
            const row = maybe orelse break;
            try testing.expect(row.len >= 1 and row.len <= 6);
            for (row) |f| try testing.expect(f.len <= 20);
            rows += 1;
            if (rows > len + 1) return error.TestUnexpectedResult; // must make progress
        } else |_| {}
    }
}
