// Runner for fix_server_trading example.
// Spawns the server, logs on, sends a NewOrderSingle order, receives an
// ExecutionReport (35=8), then logs out.
//
// Invoked by `zig build test-runner-fix-trading`.
// argv[1]: server binary path
// argv[2]: label

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const PORT: u16 = 9053;
const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL: missing label\n", .{});
        std.process.exit(1);
    };

    run(process.io, server_path) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, server_path: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, PORT, WAIT_MS);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = PORT,
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
