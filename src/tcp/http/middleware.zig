//! zix http middleware

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;

pub const NextFn = *const fn (req: *Request, res: *Response, ctx: *Context) anyerror!void;

pub const Middleware = struct {
    name: []const u8,
    handle: *const fn (req: *Request, res: *Response, ctx: *Context, next: NextFn) anyerror!void,
};
