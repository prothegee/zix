// Test runner for zix.Fix.Server (fix_server_*).
// Spawns the server, performs Logon -> send order -> recv echo -> Logout, kills server.
//
// Invoked by `zig build test-runner-fix-<model>`.
// argv[1]: server binary path, argv[2]: label, argv[3]: port.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const WAIT_MS: u64 = 5000;
const COMP_ID: []const u8 = "RUNNER";
const TARGET_ID: []const u8 = "ZIX";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL fix: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL fix: missing label\n", .{});
        std.process.exit(1);
    };
    const port_str = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing port\n", .{label});
        std.process.exit(1);
    };
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    run(process.io, server_path, port) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    common.printPass(label);
}

fn run(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, WAIT_MS);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = port,
        .comp_id = COMP_ID,
        .target_comp_id = TARGET_ID,
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
