//! zix http router

const std = @import("std");
const Request = @import("request.zig").Request;
const PathParam = @import("request.zig").PathParam;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;

pub const HandlerFn = *const fn (req: *Request, res: *Response, ctx: *Context) anyerror!void;

const RouteKind = enum { exact, prefix, param };

const Route = struct {
    path: []const u8,
    handler: HandlerFn,
    kind: RouteKind = .exact,
};

pub const Router = struct {
    routes: std.ArrayList(Route),
    allocator: std.mem.Allocator,

    /// Brief:
    /// Initialize the router with the given allocator
    ///
    /// Param:
    /// allocator - std.mem.Allocator
    ///
    /// Return:
    /// Router
    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .routes = .empty, .allocator = allocator };
    }

    /// Brief:
    /// Free all route storage
    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
    }

    /// Brief:
    /// Register a handler for an exact URL path
    ///
    /// Note:
    /// - Matches only when the request path equals path character-for-character
    ///
    /// Param:
    /// path    - []const u8
    /// handler - HandlerFn
    ///
    /// Return:
    /// !void
    pub fn register(self: *Router, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .path = path, .handler = handler, .kind = .exact });
    }

    /// Brief:
    /// Register a handler for a URL prefix
    ///
    /// Note:
    /// - Matches the prefix itself and any sub-path below it
    /// - "/api" matches "/api", "/api/foo", "/api/foo/bar" but NOT "/apiv2"
    ///
    /// Param:
    /// prefix  - []const u8 (no trailing slash)
    /// handler - HandlerFn
    ///
    /// Return:
    /// !void
    pub fn registerPrefix(self: *Router, prefix: []const u8, handler: HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .path = prefix, .handler = handler, .kind = .prefix });
    }

    /// Brief:
    /// Register a handler for a parameterized URL pattern
    ///
    /// Note:
    /// - Segments prefixed with ':' are named captures; others must match literally
    /// - "/users/:id" matches "/users/alice" and captures id="alice"
    /// - Captured values are read via req.pathParam("id") inside the handler
    ///
    /// Param:
    /// pattern - []const u8 (e.g. "/users/:id/posts/:post_id")
    /// handler - HandlerFn
    ///
    /// Return:
    /// !void
    pub fn registerParam(self: *Router, pattern: []const u8, handler: HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .path = pattern, .handler = handler, .kind = .param });
    }

    /// Brief:
    /// Dispatch the request to the best matching route
    ///
    /// Note:
    /// - Pass 1 exact:  first exact match wins
    /// - Pass 2 param:  first parameterized pattern that matches wins; params written to req.path_params
    /// - Pass 3 prefix: longest matching prefix wins
    /// - Priority is independent of registration order
    ///
    /// Param:
    /// req - *Request
    /// res - *Response
    /// ctx - *Context
    ///
    /// Return:
    /// !bool
    pub fn dispatch(self: *Router, req: *Request, res: *Response, ctx: *Context) !bool {
        const p = req.path();

        // Pass 1: exact
        for (self.routes.items) |route| {
            if (route.kind == .exact and std.mem.eql(u8, route.path, p)) {
                try route.handler(req, res, ctx);
                return true;
            }
        }

        // Pass 2: parameterized (first match wins)
        for (self.routes.items) |route| {
            if (route.kind == .param) {
                if (try matchParam(route.path, p, req)) {
                    try route.handler(req, res, ctx);
                    return true;
                }
            }
        }

        // Pass 3: prefix (longest match wins)
        var best_len: usize = 0;
        var best_handler: ?HandlerFn = null;
        for (self.routes.items) |route| {
            if (route.kind == .prefix) {
                const at_boundary = p.len == route.path.len or p[route.path.len] == '/';
                if (std.mem.startsWith(u8, p, route.path) and at_boundary and route.path.len > best_len) {
                    best_len = route.path.len;
                    best_handler = route.handler;
                }
            }
        }
        if (best_handler) |h| {
            try h(req, res, ctx);
            return true;
        }

        return false;
    }
};

// Match a parameterized pattern against a concrete path.
// On success, populates req.path_params (allocated from req.allocator) and returns true.
fn matchParam(pattern: []const u8, path: []const u8, req: *Request) !bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    var params: std.ArrayList(PathParam) = .empty;

    while (true) {
        const pat_seg = pat_it.next();
        const path_seg = path_it.next();
        if (pat_seg == null and path_seg == null) break;
        if (pat_seg == null or path_seg == null) return false;
        const ps = pat_seg.?;
        const vs = path_seg.?;
        if (std.mem.startsWith(u8, ps, ":")) {
            if (vs.len == 0) return false;
            try params.append(req.allocator, .{ .name = ps[1..], .value = vs });
        } else {
            if (!std.mem.eql(u8, ps, vs)) return false;
        }
    }

    req.path_params = params.items;
    return true;
}
