//! zix http router

const std = @import("std");
const Request = @import("request.zig").Request;
const PathParam = @import("request.zig").PathParam;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;

pub const HandlerFn = *const fn (req: *Request, res: *Response, ctx: *Context) anyerror!void;

const RouteKind = enum(u8) { EXACT, PREFIX, PARAM };

const Route = struct {
    path: []const u8,
    handler: HandlerFn,
    kind: RouteKind = .EXACT,
};

pub const Router = struct {
    routes: std.MultiArrayList(Route) = .{},
    // O(1) hash lookup for exact-match routes, param/prefix stay in `routes`.
    // Insertions and lookups use the request path string directly as the key.
    exact_map: std.StringHashMapUnmanaged(HandlerFn) = .empty,
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
        return .{ .allocator = allocator };
    }

    /// Brief:
    /// Free all route storage
    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
        self.exact_map.deinit(self.allocator);
    }

    /// Brief:
    /// Register a handler for an exact URL path
    ///
    /// Note:
    /// - Matches only when the request path equals path character-for-character
    /// - Inserted into both `routes` (for listing/iteration) and `exact_map` (for O(1) dispatch)
    ///
    /// Param:
    /// path    - []const u8
    /// handler - HandlerFn
    ///
    /// Return:
    /// !void
    pub fn register(self: *Router, path: []const u8, handler: HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .path = path, .handler = handler, .kind = .EXACT });
        try self.exact_map.put(self.allocator, path, handler);
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
        try self.routes.append(self.allocator, .{ .path = prefix, .handler = handler, .kind = .PREFIX });
    }

    /// Brief:
    /// Register a handler for a parameterized URL pattern
    ///
    /// Note:
    /// - Segments prefixed with ':' are named captures others must match literally
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
        try self.routes.append(self.allocator, .{ .path = pattern, .handler = handler, .kind = .PARAM });
    }

    /// Brief:
    /// Dispatch the request to the best matching route
    ///
    /// Note:
    /// - Pass 1 exact:  O(1) hash lookup via exact_map
    /// - Pass 2 param:  first parameterized pattern that matches wins params written to req.path_params
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

        // Pass 1: exact, O(1) hash lookup
        if (self.exact_map.get(p)) |handler| {
            try handler(req, res, ctx);
            return true;
        }

        const kinds = self.routes.items(.kind);
        const paths = self.routes.items(.path);
        const handlers = self.routes.items(.handler);

        // Pass 2: parameterized (first match wins), kind-only scan until match
        for (kinds, 0..) |kind, i| {
            if (kind == .PARAM) {
                if (try matchParam(paths[i], p, req)) {
                    try handlers[i](req, res, ctx);
                    return true;
                }
            }
        }

        // Pass 3: prefix (longest match wins)
        var best_len: usize = 0;
        var best_handler: ?HandlerFn = null;
        for (kinds, paths, handlers) |kind, path, handler| {
            if (kind == .PREFIX) {
                const at_boundary = p.len == path.len or p[path.len] == '/';
                if (std.mem.startsWith(u8, p, path) and at_boundary and path.len > best_len) {
                    best_len = path.len;
                    best_handler = handler;
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: http router matchParam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var req = Request{
        .inner = undefined,
        .reader = undefined,
        .allocator = allocator,
    };

    try std.testing.expect(try matchParam("/users/:id", "/users/alice", &req));
    try std.testing.expectEqualStrings("id", req.path_params[0].name);
    try std.testing.expectEqualStrings("alice", req.path_params[0].value);

    try std.testing.expect(try matchParam("/:tenant/:branch", "/acme/main", &req));
    try std.testing.expectEqualStrings("tenant", req.path_params[0].name);
    try std.testing.expectEqualStrings("acme", req.path_params[0].value);
    try std.testing.expectEqualStrings("branch", req.path_params[1].name);
    try std.testing.expectEqualStrings("main", req.path_params[1].value);

    try std.testing.expect(!try matchParam("/users/:id", "/users", &req));
    try std.testing.expect(!try matchParam("/users/:id", "/users/alice/posts", &req));
}

fn mockHandler(req: *Request, res: *Response, ctx: *Context) !void {
    _ = req;
    _ = res;
    _ = ctx;
}

test "zix test: http router registration" {
    var router = Router.init(std.testing.allocator);
    defer router.deinit();

    try router.register("/about", mockHandler);
    try router.registerPrefix("/api", mockHandler);
    try router.registerParam("/users/:id", mockHandler);

    try std.testing.expectEqual(@as(usize, 3), router.routes.len);
    try std.testing.expectEqual(RouteKind.EXACT, router.routes.items(.kind)[0]);
    try std.testing.expectEqualStrings("/about", router.routes.items(.path)[0]);
    try std.testing.expectEqual(RouteKind.PREFIX, router.routes.items(.kind)[1]);
    try std.testing.expectEqualStrings("/api", router.routes.items(.path)[1]);
    try std.testing.expectEqual(RouteKind.PARAM, router.routes.items(.kind)[2]);
    try std.testing.expectEqualStrings("/users/:id", router.routes.items(.path)[2]);
}
