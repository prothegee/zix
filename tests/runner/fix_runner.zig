// Test runner for zix.Fix.Server (fix_server_1_async, port 9500).
// Spawns the server, performs Logon -> send order -> recv echo -> Logout, kills server.
//
// Invoked by `zig build test-runner-fix`.
// The server binary path is passed as argv[1] by build.zig.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const PORT: u16 = 9500;
const WAIT_MS: u64 = 5000;
const COMP_ID: []const u8 = "RUNNER";
const TARGET_ID: []const u8 = "ZIX";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    run(process) catch |err| {
        std.debug.print("FAIL fix: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("PASS fix\n", .{});
}

fn run(process: std.process.Init) !void {
    const io = process.io;

    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse return error.MissingServerPath;

    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, PORT, WAIT_MS);

    var client = try zix.Fix.Client.connect(.{
        .ip = "127.0.0.1",
        .port = PORT,
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
