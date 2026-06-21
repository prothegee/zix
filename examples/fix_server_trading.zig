const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9053;
const COMP_ID: []const u8 = "BROKER_ZIX";
const LOG_DIR: []const u8 = "./logs";
const LOG_FILE: []const u8 = "fix_trading";
const ORDERS_FILE: []const u8 = "orders.jsonl";

// --------------------------------------------------------- //

fn isoTimestamp(buf: []u8) []const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    const total_secs: u64 = @intCast(ts.sec);
    const sod = total_secs % 86400;
    var days = total_secs / 86400;
    const hour = sod / 3600;
    const minute = (sod % 3600) / 60;
    const sec = sod % 60;
    var yr: u64 = 1970;
    while (true) {
        const dy: u64 = if ((yr % 4 == 0 and yr % 100 != 0) or yr % 400 == 0) 366 else 365;
        if (days < dy) break;
        days -= dy;
        yr += 1;
    }
    const leap = (yr % 4 == 0 and yr % 100 != 0) or yr % 400 == 0;
    const month_days = [_]u64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var mo: u64 = 1;
    for (month_days) |md| {
        if (days < md) break;
        days -= md;
        mo += 1;
    }
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yr, mo, days + 1, hour, minute, sec }) catch "1970-01-01T00:00:00Z";
}

// --------------------------------------------------------- //

var order_counter: std.atomic.Value(u32) = .init(1);

fn nextId() u32 {
    return order_counter.fetchAdd(1, .monotonic);
}

fn appendRecord(record: []const u8) void {
    const fd = std.posix.openat(
        std.posix.AT.FDCWD,
        ORDERS_FILE,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
        0o644,
    ) catch return;
    defer _ = std.posix.system.close(fd);
    _ = std.posix.system.write(fd, record.ptr, record.len);
    _ = std.posix.system.write(fd, "\n".ptr, 1);
}

// --------------------------------------------------------- //

fn handleNewOrder(fields: []const zix.Fix.Field, ctx: *zix.Fix.Context) void {
    if (ctx.isExpired()) return;

    const cl_ord_id = zix.Fix.getField(fields, .ClOrdID) orelse return;
    const symbol = zix.Fix.getField(fields, .Symbol) orelse return;
    const side_str = zix.Fix.getField(fields, .Side) orelse return;
    const qty_str = zix.Fix.getField(fields, .OrderQty) orelse "0";
    const price_str = zix.Fix.getField(fields, .Price) orelse "0";
    const account = zix.Fix.getField(fields, .Account) orelse "UNKNOWN";

    const record_id = nextId();
    var order_id_buf: [20]u8 = undefined;
    const order_id_str = std.fmt.bufPrint(&order_id_buf, "ORD-{d:0>6}", .{record_id}) catch return;

    var exec_id_buf: [20]u8 = undefined;
    const exec_id_str = std.fmt.bufPrint(&exec_id_buf, "EXEC-{d:0>6}", .{record_id}) catch return;

    const side_label: []const u8 = if (std.mem.eql(u8, side_str, "1")) "buy" else "sell";

    var ts_buf: [32]u8 = undefined;
    const ts = isoTimestamp(&ts_buf);

    var rec_buf: [640]u8 = undefined;
    const rec = std.fmt.bufPrint(&rec_buf,
        \\{{"id":{d},"timestamp":"{s}","account":"{s}","sender":"{s}","symbol":"{s}","side":"{s}","qty":{s},"price":{s},"cl_ord_id":"{s}","order_id":"{s}","status":"new"}}
    , .{ record_id, ts, account, ctx.sender_comp_id, symbol, side_label, qty_str, price_str, cl_ord_id, order_id_str }) catch return;
    appendRecord(rec);

    ctx.sendMessage(zix.Fix.MsgType.ExecutionReport, &[_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = cl_ord_id },
        .{ .tag = .OrderID, .value = order_id_str },
        .{ .tag = .ExecID, .value = exec_id_str },
        .{ .tag = .ExecType, .value = "0" },
        .{ .tag = .OrdStatus, .value = "0" },
        .{ .tag = .Symbol, .value = symbol },
        .{ .tag = .Side, .value = side_str },
        .{ .tag = .OrderQty, .value = qty_str },
        .{ .tag = .Account, .value = account },
    });
}

fn handleCancelOrder(fields: []const zix.Fix.Field, ctx: *zix.Fix.Context) void {
    if (ctx.isExpired()) return;

    const cl_ord_id = zix.Fix.getField(fields, .ClOrdID) orelse return;
    const orig_cl_ord_id = zix.Fix.getField(fields, .OrigClOrdID) orelse return;
    const symbol = zix.Fix.getField(fields, .Symbol) orelse return;
    const side_str = zix.Fix.getField(fields, .Side) orelse return;
    const account = zix.Fix.getField(fields, .Account) orelse "UNKNOWN";

    const record_id = nextId();
    var order_id_buf: [20]u8 = undefined;
    const order_id_str = std.fmt.bufPrint(&order_id_buf, "ORD-{d:0>6}", .{record_id}) catch return;

    var exec_id_buf: [20]u8 = undefined;
    const exec_id_str = std.fmt.bufPrint(&exec_id_buf, "EXEC-{d:0>6}", .{record_id}) catch return;

    const side_label: []const u8 = if (std.mem.eql(u8, side_str, "1")) "buy" else "sell";

    var ts_buf: [32]u8 = undefined;
    const ts = isoTimestamp(&ts_buf);

    var rec_buf: [640]u8 = undefined;
    const rec = std.fmt.bufPrint(&rec_buf,
        \\{{"id":{d},"timestamp":"{s}","account":"{s}","sender":"{s}","symbol":"{s}","side":"{s}","orig_cl_ord_id":"{s}","cl_ord_id":"{s}","order_id":"{s}","status":"cancelled"}}
    , .{ record_id, ts, account, ctx.sender_comp_id, symbol, side_label, orig_cl_ord_id, cl_ord_id, order_id_str }) catch return;
    appendRecord(rec);

    ctx.sendMessage(zix.Fix.MsgType.ExecutionReport, &[_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = cl_ord_id },
        .{ .tag = .OrigClOrdID, .value = orig_cl_ord_id },
        .{ .tag = .OrderID, .value = order_id_str },
        .{ .tag = .ExecID, .value = exec_id_str },
        .{ .tag = .ExecType, .value = "4" },
        .{ .tag = .OrdStatus, .value = "4" },
        .{ .tag = .Symbol, .value = symbol },
        .{ .tag = .Side, .value = side_str },
        .{ .tag = .Account, .value = account },
    });
}

// --------------------------------------------------------- //

const Routes = [_]zix.Fix.Route{
    .{ .msg_type = zix.Fix.MsgType.NewOrderSingle, .handler = handleNewOrder, .timeout_ms = 500 },
    .{ .msg_type = zix.Fix.MsgType.OrderCancelRequest, .handler = handleCancelOrder, .timeout_ms = 500 },
};

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};

    var logger = try zix.Logger.init(std.heap.smp_allocator, .{
        .save_path = LOG_DIR,
        .save_file = LOG_FILE,
        .save_min_level = .INFO,
        .console = .ALWAYS,
    });
    defer logger.deinit();

    var server = try zix.Fix.Server.init(
        &Routes,
        .{
            .io = io,
            .ip = IP,
            .port = PORT,
            .comp_id = COMP_ID,
            .dispatch_model = .ASYNC,
            .logger = &logger,
            .conn_timeout_ms = 60_000,
            .handler_timeout_ms = 200,
        },
    );
    defer server.deinit();

    try server.run();
}
