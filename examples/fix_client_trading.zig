const std = @import("std");
const zix = @import("zix");

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9500;
const COMP_ID: []const u8 = "TRADER_ALPHA";
const TARGET_COMP_ID: []const u8 = "BROKER_ZIX";

// --------------------------------------------------------- //

fn recvExecReport(client: *zix.Fix.Client, io: std.Io) !void {
    const raw = try client.recvMessage(io);
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const nf = try zix.Fix.parseFields(raw, &fields);
    const fslice = fields[0..nf];

    const msg_type = zix.Fix.getField(fslice, .MsgType) orelse "(?)";
    const ord_status = zix.Fix.getField(fslice, .OrdStatus) orelse "(?)";
    const exec_type = zix.Fix.getField(fslice, .ExecType) orelse "(?)";
    const symbol = zix.Fix.getField(fslice, .Symbol) orelse "(?)";
    const order_id = zix.Fix.getField(fslice, .OrderID) orelse "(?)";

    const status_label: []const u8 = switch (if (ord_status.len > 0) ord_status[0] else '?') {
        '0' => "New",
        '1' => "PartiallyFilled",
        '2' => "Filled",
        '4' => "Cancelled",
        '8' => "Rejected",
        else => ord_status,
    };

    std.debug.print("  recv 35={s}: OrderID={s} Symbol={s} OrdStatus={s}({s}) ExecType={s}\n", .{ msg_type, order_id, symbol, status_label, ord_status, exec_type });
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    const io = process.io;

    var client = try zix.Fix.Client.connect(.{
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .comp_id = COMP_ID,
        .target_comp_id = TARGET_COMP_ID,
    }, io);
    defer client.deinit(io);

    try client.logon(io, 30);
    std.debug.print("Logon OK (sender={s} target={s})\n", .{ COMP_ID, TARGET_COMP_ID });

    // Buy 100 GOOGL for account ALPHABET_INC
    std.debug.print("\n[1] NewOrderSingle Buy GOOGL (Account=ALPHABET_INC)\n", .{});
    try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &[_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "CLT-BUY-001" },
        .{ .tag = .Account, .value = "ALPHABET_INC" },
        .{ .tag = .Symbol, .value = "GOOGL" },
        .{ .tag = .Side, .value = "1" },
        .{ .tag = .OrderQty, .value = "100" },
        .{ .tag = .OrdType, .value = "2" },
        .{ .tag = .Price, .value = "175.50" },
    });
    try recvExecReport(&client, io);

    // Cancel the buy order
    std.debug.print("\n[2] OrderCancelRequest for CLT-BUY-001\n", .{});
    try client.sendMessage(io, zix.Fix.MsgType.OrderCancelRequest, &[_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "CLT-CXL-001" },
        .{ .tag = .OrigClOrdID, .value = "CLT-BUY-001" },
        .{ .tag = .Account, .value = "ALPHABET_INC" },
        .{ .tag = .Symbol, .value = "GOOGL" },
        .{ .tag = .Side, .value = "1" },
        .{ .tag = .OrderQty, .value = "100" },
    });
    try recvExecReport(&client, io);

    // Sell EUR for account APPLE_INC
    std.debug.print("\n[3] NewOrderSingle Sell EUR (Account=APPLE_INC)\n", .{});
    try client.sendMessage(io, zix.Fix.MsgType.NewOrderSingle, &[_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "CLT-SELL-001" },
        .{ .tag = .Account, .value = "APPLE_INC" },
        .{ .tag = .Symbol, .value = "EUR" },
        .{ .tag = .Currency, .value = "EUR" },
        .{ .tag = .Side, .value = "2" },
        .{ .tag = .OrderQty, .value = "50000" },
        .{ .tag = .OrdType, .value = "2" },
        .{ .tag = .Price, .value = "1.0850" },
    });
    try recvExecReport(&client, io);

    // Cancel the sell order
    std.debug.print("\n[4] OrderCancelRequest for CLT-SELL-001\n", .{});
    try client.sendMessage(io, zix.Fix.MsgType.OrderCancelRequest, &[_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "CLT-CXL-002" },
        .{ .tag = .OrigClOrdID, .value = "CLT-SELL-001" },
        .{ .tag = .Account, .value = "APPLE_INC" },
        .{ .tag = .Symbol, .value = "EUR" },
        .{ .tag = .Side, .value = "2" },
        .{ .tag = .OrderQty, .value = "50000" },
    });
    try recvExecReport(&client, io);

    std.debug.print("\nLogout\n", .{});
    try client.logout(io);
    std.debug.print("Session closed.\n", .{});
}
