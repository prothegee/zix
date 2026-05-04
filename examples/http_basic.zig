const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9000;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9000/"
pub fn homeHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("hello from zix");
}

// curl usage: curl -X GET "http://localhost:9000/about"
pub fn aboutHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = ctx;
    try res.send("zix basic server example");
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(.{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
    });
    defer server.deinit();

    server.registerHandler("/", homeHandler);
    server.registerHandler("/about", aboutHandler);

    try server.run();
}
