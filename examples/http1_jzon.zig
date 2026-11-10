//! ZIX example http1 jzon
//!
//! ### file: examples/http1_jzon.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 routes that read a JSON request and answer with a JSON response through
//! `zix.jzon`.
//!
//! ### note:
//!
//! Strings are borrowed: a parsed string with no escape points into the request body,
//! which stays alive for the whole handler. Nothing on the response path allocates: a
//! render is handed a fixed RESPONSE_MAX buffer and fails rather than growing it.
//! examples/http1_json.zig shows the same kind of route through std.json.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;
const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9033;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const MAX_RECV_BUF:usize = 16 * 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

/// Room for the largest answer any route here renders. A render that does not fit
/// fails, so this number is the whole response budget.
const RESPONSE_MAX:usize = 1024;

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

/// What an accepted order is answered with.
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
        .{
            .sku = "AB-1",
            .qty = 2,
            .price_cents = 1299,
        },
        .{
            .sku = "CD-2",
            .qty = 1,
            .price_cents = 4500,
        },
    },
};

// --------------------------------------------------------- //

/// What the order is worth, in cents.
fn totalCents(order: Order) i64 {
    var total: i64 = 0;

    for (order.lines) |line| total += line.price_cents * @as(i64, line.qty);

    return total;
}

/// Render a value into a stack buffer and answer with it.
fn sendValue(res: *zix.Http1.Response, value: anytype) !void {
    var buf: [RESPONSE_MAX]u8 = undefined;

    const len = try jzon.json.serialize(&buf, value, .{ .strategy = .GENERATED });

    try res.sendJson(buf[0..len]);
}

/// Answer with a rendered Refusal. The caller sets the status first.
fn sendRefusal(res: *zix.Http1.Response, reason: []const u8) !void {
    try sendValue(res, Refusal{ .reason = reason });
}

/// Render a receipt off the order and answer with it.
fn sendReceipt(res: *zix.Http1.Response, order: Order) !void {
    const receipt: Receipt = .{
        .order_id = order.id,
        .customer = order.customer,
        .lines = order.lines.len,
        .total_cents = totalCents(order),
    };

    try sendValue(res, receipt);
}

/// Read a POST body into an Order.
///
/// Param:
/// unknown - jzon.json.Unknown (comptime, what happens to a key Order does not declare)
///
/// Return:
/// - Order (the parsed order)
/// - null, after answering with the status and the reason, so the caller sends nothing
fn readOrder(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
    comptime unknown: jzon.json.Unknown,
) !?Order {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendRefusal(res, "method not allowed");

        return null;
    }

    const body = req.body();
    if (body.len == 0) {
        res.setStatus(.BAD_REQUEST);
        try sendRefusal(res, "empty body");

        return null;
    }

    // ctx.allocator is the per-request arena: whatever the parse takes is released
    // with the request. Borrowed strings point into body, which outlives every send.
    return jzon.json.deserialize(Order, ctx.allocator, body, .{
        .strategy = .GENERATED,
        .strings = .BORROW,
        .unknown = unknown,
    }) catch |err| {
        res.setStatus(.BAD_REQUEST);
        try sendRefusal(res, @errorName(err));

        return null;
    };
}

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9033/order"
// curl usage:
// curl -X POST "http://localhost:9033/order" -H "Content-Type: application/json" \
//     -d '{"id":42,"customer":"Ada","status":"PENDING","tags":[],
//     "lines":[{"sku":"AB-1","qty":2,"price_cents":1299}]}'
fn orderHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (req.method() == .GET) {
        try sendValue(res, CATALOG_ORDER);
        return;
    }

    const order = try readOrder(req, res, ctx, .REJECT) orelse return;

    try sendReceipt(res, order);
}

// A key Order does not declare is refused by /order and skipped here. That is the
// one difference between the two routes.
//
// curl usage:
// curl -X POST "http://localhost:9033/order/lenient" -H "Content-Type: application/json" \
//     -d '{"id":42,"customer":"Ada","status":"PENDING","tags":[],"lines":[],
//     "coupon":{"code":"X","off":5}}'
fn lenientOrderHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const order = try readOrder(req, res, ctx, .SKIP) orelse return;

    try sendReceipt(res, order);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/order",
        .handler = orderHandler,
    },
    .{
        .path = "/order/lenient",
        .handler = lenientOrderHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

