//! A thin push-parser wrapper over the vendored Expat.
//!
//! `Parser(Handler)` calls three methods of `Handler`, each taking the
//! parser so it can stop it or ask where it is:
//!
//!   startElement(h: *Handler, p: *P, name: []const u8) void
//!   endElement(h: *Handler, p: *P, name: []const u8) void
//!   characters(h: *Handler, p: *P, bytes: []const u8) void
//!
//! Safety: Expat is built without DTD support and without general entity
//! expansion (vendor/expat/expat_config.h), and a document type declaration
//! is refused outright, so a hostile document cannot make entities expand.
//! The predefined entities and character references still work. The parser
//! holds no more than the current token in memory; the caller feeds it in
//! chunks.

const std = @import("std");
const c = @import("wiki_c");

pub const Error = error{
    /// Not well-formed XML, or a DOCTYPE was present.
    Malformed,
    /// A handler called `stop`.
    Stopped,
    OutOfMemory,
};

pub fn Parser(comptime Handler: type) type {
    return struct {
        const Self = @This();

        parser: c.XML_Parser,
        handler: *Handler,

        /// `self` must not move after `init` (Expat keeps a pointer to it).
        pub fn init(self: *Self, handler: *Handler) error{OutOfMemory}!void {
            const p = c.XML_ParserCreate(null) orelse return error.OutOfMemory;
            self.* = .{ .parser = p, .handler = handler };
            c.XML_SetUserData(p, self);
            c.XML_SetElementHandler(p, onStart, onEnd);
            c.XML_SetCharacterDataHandler(p, onChars);
            c.XML_SetStartDoctypeDeclHandler(p, onDoctype);
        }

        pub fn deinit(self: *Self) void {
            c.XML_ParserFree(self.parser);
            self.* = undefined;
        }

        /// Feeds `data`; `final` marks the end of the document.
        pub fn feed(self: *Self, data: []const u8, final: bool) Error!void {
            var rest = data;
            // Expat takes an int length; chunks are small, but stay correct.
            while (true) {
                const n: usize = @min(rest.len, 1 << 30);
                const is_last = final and n == rest.len;
                const st = c.XML_Parse(self.parser, @ptrCast(rest.ptr), @intCast(n), @intFromBool(is_last));
                if (st == c.XML_STATUS_ERROR) {
                    return switch (c.XML_GetErrorCode(self.parser)) {
                        c.XML_ERROR_ABORTED => error.Stopped,
                        c.XML_ERROR_NO_MEMORY => error.OutOfMemory,
                        else => error.Malformed,
                    };
                }
                rest = rest[n..];
                if (rest.len == 0) return;
            }
        }

        /// Makes the current or next `feed` fail with `error.Stopped`.
        pub fn stop(self: *Self) void {
            _ = c.XML_StopParser(self.parser, c.XML_FALSE);
        }

        /// Offset, in bytes fed so far, of the start of the current event.
        pub fn byteIndex(self: *const Self) i64 {
            return @intCast(c.XML_GetCurrentByteIndex(self.parser));
        }

        /// Length in bytes of the current event.
        pub fn byteCount(self: *const Self) i64 {
            return @intCast(c.XML_GetCurrentByteCount(self.parser));
        }

        fn self_(ud: ?*anyopaque) *Self {
            return @ptrCast(@alignCast(ud.?));
        }

        fn onStart(ud: ?*anyopaque, name: [*c]const c.XML_Char, _: [*c][*c]const c.XML_Char) callconv(.c) void {
            const s = self_(ud);
            s.handler.startElement(s, std.mem.span(@as([*:0]const u8, @ptrCast(name))));
        }

        fn onEnd(ud: ?*anyopaque, name: [*c]const c.XML_Char) callconv(.c) void {
            const s = self_(ud);
            s.handler.endElement(s, std.mem.span(@as([*:0]const u8, @ptrCast(name))));
        }

        fn onChars(ud: ?*anyopaque, text: [*c]const c.XML_Char, len: c_int) callconv(.c) void {
            const s = self_(ud);
            if (len <= 0) return;
            s.handler.characters(s, @as([*]const u8, @ptrCast(text))[0..@intCast(len)]);
        }

        fn onDoctype(ud: ?*anyopaque, _: [*c]const c.XML_Char, _: [*c]const c.XML_Char, _: [*c]const c.XML_Char, _: c_int) callconv(.c) void {
            // Refuse any document type declaration: dumps have none.
            _ = c.XML_StopParser(self_(ud).parser, c.XML_FALSE);
        }
    };
}
