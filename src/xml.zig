//! A small push-style wrapper over xml-zig, for the connectors that hand a whole document to a handler
//! (feeds, sitemaps). The Wikipedia connector, which reads gigabytes, uses xml-zig's pull reader directly.
//!
//! `Parser(Handler)` calls three methods of `Handler`, each taking the parser so it can stop it:
//!
//!   startElement(h: *Handler, p: *P, name: []const u8, attrs: Attrs) void
//!   endElement(h: *Handler, p: *P, name: []const u8) void
//!   characters(h: *Handler, p: *P, bytes: []const u8) void
//!
//! Names are as written in the document (`dc:creator`); no namespace is resolved. A document type
//! declaration is refused, so no entity can expand beyond the five predefined ones and character
//! references. The document is collected until `feed(..., true)` and parsed then, so it must fit in
//! memory (the callers already hold it whole; `max_document_bytes` bounds it).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const xmlzig = @import("xmlzig");

pub const max_document_bytes = 256 * 1024 * 1024;

pub const Error = error{
    /// Not well-formed XML, or a DOCTYPE was present.
    Malformed,
    /// A handler called `stop`.
    Stopped,
    OutOfMemory,
};

/// The attributes of a start tag.
pub const Attrs = struct {
    list: []const xmlzig.Attribute,

    /// The value of attribute `name` (as written, `xml:lang`), if present. The slice is valid during the
    /// handler call only.
    pub fn get(self: Attrs, name: []const u8) ?[]const u8 {
        for (self.list) |a| if (std.mem.eql(u8, a.name.qualified, name)) return a.value;
        return null;
    }
};

pub fn Parser(comptime Handler: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        handler: *Handler,
        buf: std.ArrayList(u8) = .empty,
        stopped: bool = false,

        /// `self` must not move between `init` and the end of `feed`.
        pub fn init(self: *Self, gpa: Allocator, handler: *Handler) error{OutOfMemory}!void {
            self.* = .{ .gpa = gpa, .handler = handler };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.gpa);
            self.* = undefined;
        }

        /// Collects `data`; with `final` set, parses the whole document and calls the handler.
        pub fn feed(self: *Self, data: []const u8, final: bool) Error!void {
            if (self.buf.items.len + data.len > max_document_bytes) return error.Malformed;
            try self.buf.appendSlice(self.gpa, data);
            if (!final) return;
            return self.parse();
        }

        /// Makes the current or next `feed` fail with `error.Stopped`.
        pub fn stop(self: *Self) void {
            self.stopped = true;
        }

        fn parse(self: *Self) Error!void {
            var src: Io.Reader = .fixed(self.buf.items);
            var rd = xmlzig.Reader.init(self.gpa, &src, .{ .namespaces = false, .doctype = .reject, .max_input_bytes = max_document_bytes }, null);
            defer rd.deinit();
            var depth: u32 = 0;
            while (true) {
                const ev = rd.next() catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Malformed,
                };
                switch (ev) {
                    .start_element => |s| {
                        depth += 1;
                        self.handler.startElement(self, s.name.qualified, .{ .list = s.attributes });
                    },
                    .end_element => |e| {
                        self.handler.endElement(self, e.name.qualified);
                        depth -= 1;
                    },
                    .text, .cdata => |t| if (t.len > 0) self.handler.characters(self, t),
                    .end_of_document => return,
                    else => {},
                }
                if (self.stopped) return error.Stopped;
            }
        }
    };
}

const testing = std.testing;

const Collect = struct {
    out: std.ArrayList(u8) = .empty,
    stop_at: ?[]const u8 = null,
    const P = Parser(Collect);

    pub fn startElement(self: *Collect, p: *P, name: []const u8, attrs: Attrs) void {
        self.out.print(testing.allocator, "<{s}", .{name}) catch return p.stop();
        if (attrs.get("xml:lang")) |l| self.out.print(testing.allocator, "[{s}]", .{l}) catch return p.stop();
        if (self.stop_at) |s| if (std.mem.eql(u8, s, name)) p.stop();
    }
    pub fn endElement(self: *Collect, p: *P, name: []const u8) void {
        self.out.print(testing.allocator, ">{s}", .{name}) catch p.stop();
    }
    pub fn characters(self: *Collect, p: *P, bytes: []const u8) void {
        self.out.appendSlice(testing.allocator, bytes) catch p.stop();
    }
};

fn run(doc: []const u8, h: *Collect) Error!void {
    var p: Collect.P = undefined;
    try p.init(testing.allocator, h);
    defer p.deinit();
    // In two pieces, as callers may feed them.
    const mid = doc.len / 2;
    try p.feed(doc[0..mid], false);
    return p.feed(doc[mid..], true);
}

test "elements, attributes as written, text with references expanded and CDATA" {
    var h: Collect = .{};
    defer h.out.deinit(testing.allocator);
    try run("<?xml version=\"1.0\"?><a xml:lang=\"en\"><dc:b>x &amp; y &#233;</dc:b><c><![CDATA[<raw>]]></c></a>", &h);
    try testing.expectEqualStrings("<a[en]<dc:bx & y é>dc:b<c<raw>>c>a", h.out.items);
}

test "malformed documents, a DOCTYPE and a handler's stop are errors" {
    var h: Collect = .{};
    defer h.out.deinit(testing.allocator);
    try testing.expectError(error.Malformed, run("<a><b></a>", &h));
    try testing.expectError(error.Malformed, run("not xml at all", &h));
    try testing.expectError(error.Malformed, run("<!DOCTYPE a [<!ENTITY e \"v\">]><a>&e;</a>", &h));
    var h2: Collect = .{ .stop_at = "b" };
    defer h2.out.deinit(testing.allocator);
    try testing.expectError(error.Stopped, run("<a><b/><c/></a>", &h2));
    try testing.expect(std.mem.indexOf(u8, h2.out.items, "<c") == null);
}

test "ISO-8859-1 and UTF-16 documents are converted" {
    var h: Collect = .{};
    defer h.out.deinit(testing.allocator);
    try run("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>caf\xe9</a>", &h);
    try testing.expectEqualStrings("<acafé>a", h.out.items);
}
