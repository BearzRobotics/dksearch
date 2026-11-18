//! dksearch HTTP adapter: routes requests to the core search service and
//! renders JSON and HTML. Imports the core; the core never imports this.
//! See docs/decisions/0004-http-api-and-frontend.md.

pub const handler = @import("handler.zig");
pub const query = @import("query.zig");
pub const html = @import("html.zig");
pub const server = @import("server.zig");
pub const admin = @import("admin.zig");
pub const docspage = @import("docspage.zig");
pub const multipart = @import("multipart.zig");
pub const accesslog = @import("accesslog.zig");

test {
    _ = handler;
    _ = query;
    _ = html;
    _ = server;
    _ = accesslog;
    _ = admin;
    _ = docspage;
    _ = multipart;
}
