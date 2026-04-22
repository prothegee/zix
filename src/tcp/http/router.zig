const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;

pub const HandlerFn = *const fn (req: *Request, res: *Response, ctx: *Context) anyerror!void;

const Route = struct {
    path: []const u8,
    handler: HandlerFn,
};

pub const Router = struct {
    routes: std.ArrayList(Route),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .routes = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
    }

    pub fn register(self: *Router, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .path = path, .handler = handler });
    }

    pub fn dispatch(self: *Router, req: *Request, res: *Response, ctx: *Context) !bool {
        const p = req.path();
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.path, p)) {
                try route.handler(req, res, ctx);
                return true;
            }
        }
        return false;
    }
};
