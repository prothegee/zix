//! gRPC and FIX protocol checks for all_runner.zig.
//!
//! Each spawns its server, waits for the port, then drives the native zix.Grpc
//! or zix.Fix client through one representative exchange.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

// --------------------------------------------------------- //

pub fn runGrpc(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = port }, io);
    defer client.deinit();

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        "runner",
        &resp_buf,
    );

    if (!std.mem.startsWith(u8, resp, "Hello,")) return error.UnexpectedResponse;
}

pub fn runGrpcLocation(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = port }, io);
    defer client.deinit();

    var req_buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos += zix.Grpc.encodeDouble(1, 106.8, req_buf[pos..]);
    pos += zix.Grpc.encodeDouble(2, -6.2, req_buf[pos..]);
    pos += zix.Grpc.encodeString(3, "runner", req_buf[pos..]);

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/location.Location/SendLocationAndSave",
        "application/grpc+proto",
        req_buf[0..pos],
        &resp_buf,
    );

    if (resp.len == 0) return error.EmptyResponse;
}

pub fn runGrpcMulti(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, 9042, common.START_TIMEOUT_MS);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 9042 }, io);
    defer client.deinit();

    var hello_req_buf: [64]u8 = undefined;
    var hello_req_pos: usize = 0;
    hello_req_pos += zix.Grpc.encodeString(1, "runner", hello_req_buf[hello_req_pos..]);

    var hello_buf: [256]u8 = undefined;
    const hello_raw = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        hello_req_buf[0..hello_req_pos],
        &hello_buf,
    );

    var hello_reader = zix.Grpc.MessageReader.init(hello_raw);
    var hello_found = false;
    while (hello_reader.next() catch null) |field| {
        if (field.field_number == 1) {
            if (!std.mem.startsWith(u8, field.payload, "Hello,")) return error.UnexpectedHelloResponse;
            hello_found = true;
        }
    }
    if (!hello_found) return error.MissingHelloField;

    var loc_req_buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos += zix.Grpc.encodeDouble(1, 106.8, loc_req_buf[pos..]);
    pos += zix.Grpc.encodeDouble(2, -6.2, loc_req_buf[pos..]);
    pos += zix.Grpc.encodeString(3, "runner", loc_req_buf[pos..]);

    var loc_resp_buf: [256]u8 = undefined;
    const loc_resp = try client.unary(
        "/location.Location/SendLocationAndSave",
        "application/grpc+proto",
        loc_req_buf[0..pos],
        &loc_resp_buf,
    );

    if (loc_resp.len == 0) return error.EmptyLocationResponse;
}

pub fn runGrpcTimeout(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, 9037, common.START_TIMEOUT_MS);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 9037 }, io);
    defer client.deinit();

    var resp_buf: [256]u8 = undefined;
    const resp = try client.unary(
        "/helloworld.Greeter/SayHello",
        "application/grpc+proto",
        "runner",
        &resp_buf,
    );

    if (!std.mem.startsWith(u8, resp, "Hello,")) return error.UnexpectedResponse;

    // Exercise the deadline-override route (Route.timeout_ms + ctx.deadline_ns): the handler extends
    // its own deadline then echoes the request, so a clean echo proves the timeout path served.
    var ext_buf: [256]u8 = undefined;
    const ext = try client.unary(
        "/helloworld.Greeter/Extended",
        "application/grpc+proto",
        "deadline-check",
        &ext_buf,
    );

    if (!std.mem.eql(u8, ext, "deadline-check")) return error.UnexpectedExtendedResponse;
}

// --------------------------------------------------------- //

pub fn runFix(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = port,
        .comp_id = "RUNNER",
        .target_comp_id = "ZIX",
    }, io);
    defer client.deinit(io);

    try client.logon(io, 30);

    const order_fields = [_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "RUN001" },
        .{ .tag = .Symbol, .value = "TEST" },
        .{ .tag = .Side, .value = "1" },
        .{ .tag = .OrderQty, .value = "1" },
        .{ .tag = .OrdType, .value = "2" },
        .{ .tag = .Price, .value = "1.00" },
    };
    try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &order_fields);

    const raw = try client.recvMessage(io);
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const field_count = try zix.Fix.parseFields(raw, &fields);
    const symbol = zix.Fix.getField(fields[0..field_count], .Symbol) orelse return error.MissingSymbolField;

    if (!std.mem.eql(u8, symbol, "TEST")) return error.UnexpectedSymbol;

    try client.logout(io);
}

pub fn runFixTrading(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, 9053, common.START_TIMEOUT_MS);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 9053,
        .comp_id = "RUNNER",
        .target_comp_id = "ZIX",
    }, io);
    defer client.deinit(io);

    try client.logon(io, 30);

    const order_fields = [_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "TR001" },
        .{ .tag = .Symbol, .value = "ZIXTEST" },
        .{ .tag = .Side, .value = "1" },
        .{ .tag = .OrderQty, .value = "100" },
        .{ .tag = .OrdType, .value = "2" },
        .{ .tag = .Price, .value = "42.00" },
    };
    try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &order_fields);

    const raw = try client.recvMessage(io);
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const field_count = try zix.Fix.parseFields(raw, &fields);
    const msg_type = zix.Fix.getField(fields[0..field_count], .MsgType) orelse return error.MissingMsgType;

    if (!std.mem.eql(u8, msg_type, "8")) return error.UnexpectedMsgType;

    try client.logout(io);
}
