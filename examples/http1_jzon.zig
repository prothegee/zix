//! HTTP/1.1 routes carrying a JSON request and a JSON response through jzon. Port: 9033.
//!
//! What:
//! - GET /order renders a record into a stack buffer and answers with it, so the
//!   write side runs without an allocator at all.
//! - POST /order reads a body back into that same record on the per-request arena,
//!   then renders a receipt built from it into a stack buffer.
//! - POST /order/lenient reads the same body with `.unknown = .SKIP`, so a client
//!   sending more keys than the record declares is still served.
//!
//! Note:
//! - Strings are borrowed rather than copied: a parsed string holding no escape
//!   points into the request body, which the engine keeps alive for the whole
//!   handler. That is what lets a receipt name the customer with nothing copied.
//! - Nothing on the response path allocates. A render is handed a fixed buffer and
//!   reports error.NoSpaceLeft rather than asking for a bigger one.
//! - examples/http1_json.zig serves a JSON route through std.json. Both examples
//!   are here on purpose: that one shows the std path, this one shows jzon.

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;

const IP: []const u8 = "127.0.0.1";
// Unique port (feature examples each own one so a test-runner can spawn them
// without colliding with the basic dispatch-model examples).
const PORT: u16 = 9033;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .ASYNC;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const WORKERS: usize = 0; // ignored by .ASYNC

/// Room for the largest answer any route here renders. A render that does not fit
/// reports error.NoSpaceLeft, so this number is the whole response budget.
const RESPONSE_MAX: usize = 1024;

// --------------------------------------------------------- //

const Status = enum { PENDING, SHIPPED, CANCELLED };

const Line = struct {
    sku: []const u8,
    qty: u32,
    price_cents: i64,
};

/// The record both directions run over: what a POST body is read into, and what
/// GET /order renders.
const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
    note: ?[]const u8 = null,
    tags: []const []const u8,
    lines: []const Line,
};

/// What an accepted order is answered with, read off the order that just arrived.
const Receipt = struct {
    order_id: u64,
    customer: []const u8,
    lines: usize,
    total_cents: i64,
};

/// What a body the record cannot take is answered with.
const Refusal = struct {
    ok: bool = false,
    reason: []const u8,
};

/// The order GET /order hands back, so a client has a body to POST straight back.
const CATALOG_ORDER: Order = .{
    .id = 4815162342,
    .customer = "Rekha Nair",
    .status = .SHIPPED,
    .note = "leave at the door",
    .tags = &.{ "priority", "gift" },
    .lines = &.{
        .{ .sku = "AB-1", .qty = 2, .price_cents = 1299 },
        .{ .sku = "CD-2", .qty = 1, .price_cents = 4500 },
    },
};

// --------------------------------------------------------- //

/// What the order is worth, in cents.
fn totalCents(order: Order) i64 {
    var total: i64 = 0;
    for (order.lines) |line| total += line.price_cents * @as(i64, line.qty);

    return total;
}

/// Answer with a rendered Refusal. The caller sets the status first.
fn sendRefusal(res: *zix.Http1.Response, reason: []const u8) !void {
    var buf: [RESPONSE_MAX]u8 = undefined;
    const len = try jzon.serialize(&buf, Refusal{ .reason = reason }, .{ .strategy = .GENERATED });

    try res.sendJson(buf[0..len]);
}

/// Render the catalog order and answer with it.
fn sendCatalogOrder(res: *zix.Http1.Response) !void {
    var buf: [RESPONSE_MAX]u8 = undefined;
    const len = try jzon.serialize(&buf, CATALOG_ORDER, .{ .strategy = .GENERATED });

    try res.sendJson(buf[0..len]);
}

/// Render a receipt off the order and answer with it.
fn sendReceipt(res: *zix.Http1.Response, order: Order) !void {
    const receipt: Receipt = .{
        .order_id = order.id,
        .customer = order.customer,
        .lines = order.lines.len,
        .total_cents = totalCents(order),
    };

    var buf: [RESPONSE_MAX]u8 = undefined;
    const len = try jzon.serialize(&buf, receipt, .{ .strategy = .GENERATED });

    try res.sendJson(buf[0..len]);
}

/// Read a POST body into an Order.
///
/// Note:
/// - Null means the answer has already been sent, so a caller returns on it rather
///   than sending a second one
///
/// Param:
/// unknown - jzon.Unknown (comptime, what happens to a key Order does not declare)
///
/// Return:
/// - The parsed order
/// - null, after answering with the status and the reason the parse refused
fn readOrder(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
    comptime unknown: jzon.Unknown,
) !?Order {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendRefusal(res, "method not allowed");

        return null;
    }

    const body = try req.body();
    if (body.len == 0) {
        res.setStatus(.BAD_REQUEST);
        try sendRefusal(res, "empty body");

        return null;
    }

    // ctx.allocator is the per-request arena: whatever the parse takes is released
    // with the request, so a handler never walks the value to free it. Borrowed
    // strings point into body, which outlives every send below.
    return jzon.deserialize(Order, ctx.allocator, body, .{
        .strategy = .GENERATED,
        .strings = .BORROW,
        .unknown = unknown,
    }) catch |failure| {
        res.setStatus(.BAD_REQUEST);
        try sendRefusal(res, @errorName(failure));

        return null;
    };
}

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9033/order"
// curl usage: curl -X POST "http://localhost:9033/order" -H "Content-Type: application/json" \
//   -d '{"id":42,"customer":"Ada","status":"PENDING","tags":[],"lines":[{"sku":"AB-1","qty":2,"price_cents":1299}]}'
fn orderHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    if (req.method() == .GET) {
        try sendCatalogOrder(res);
        return;
    }

    const parsed = try readOrder(req, res, ctx, .REJECT);
    const order = parsed orelse return;

    try sendReceipt(res, order);
}

// A key Order does not declare is refused above and skipped here, which is the one
// difference between the two routes.
//
// curl usage: curl -X POST "http://localhost:9033/order/lenient" -H "Content-Type: application/json" \
//   -d '{"id":42,"customer":"Ada","status":"PENDING","tags":[],"lines":[],"coupon":{"code":"X","off":5}}'
fn lenientOrderHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    const parsed = try readOrder(req, res, ctx, .SKIP);
    const order = parsed orelse return;

    try sendReceipt(res, order);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/order", .handler = orderHandler },
    .{ .path = "/order/lenient", .handler = lenientOrderHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run();
}
