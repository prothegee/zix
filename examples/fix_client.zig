const std = @import("std");
const zix = @import("zix");

const DEFAULT_IP: []const u8 = "127.0.0.1";
const DEFAULT_PORT: u16 = 9500;
const DEFAULT_TARGET: []const u8 = "ZIX";
const COMP_ID: []const u8 = "CLIENT";

// --------------------------------------------------------- //

// Usage:
//   zig build example-fix_client
//   zig build example-fix_client -- --port 9500 --target ZIX

pub fn main(process: std.process.Init) !void {
    var ip: []const u8 = DEFAULT_IP;
    var port: u16 = DEFAULT_PORT;
    var target: []const u8 = DEFAULT_TARGET;

    var args = std.process.Args.Iterator.init(process.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ip")) {
            ip = args.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const s = args.next() orelse return error.MissingArg;
            port = try std.fmt.parseInt(u16, s, 10);
        } else if (std.mem.eql(u8, arg, "--target")) {
            target = args.next() orelse return error.MissingArg;
        }
    }

    const io = process.io;

    var client = try zix.Fix.Client.connect(.{
        .ip = ip,
        .port = port,
        .comp_id = COMP_ID,
        .target_comp_id = target,
    }, io);
    defer client.deinit(io);

    // Logon: sends 35=A and waits for server's Logon response.
    try client.logon(io, 30);
    std.debug.print("client: sent Logon, recv Logon\n", .{});

    // Send NewOrderSingle (35=D).
    const order_fields = [_]zix.Fix.BuildField{
        .{ .tag = .ClOrdID, .value = "ORD001" },
        .{ .tag = .Symbol, .value = "AAPL" },
        .{ .tag = .Side, .value = "1" },
        .{ .tag = .OrderQty, .value = "100" },
        .{ .tag = .OrdType, .value = "2" },
        .{ .tag = .Price, .value = "150.00" },
    };
    try client.sendMessage(io, "D", &order_fields);
    std.debug.print("client: sent NewOrderSingle\n", .{});

    // Receive echo from server.
    const raw = try client.recvMessage(io);
    var fields: [zix.Fix.MAX_FIELDS]zix.Fix.Field = undefined;
    const nf = try zix.Fix.parseFields(raw, &fields);
    const fslice = fields[0..nf];
    const symbol = zix.Fix.getField(fslice, .Symbol) orelse "(missing)";
    const qty = zix.Fix.getField(fslice, .OrderQty) orelse "(missing)";
    std.debug.print("client: recv echo symbol={s} qty={s}\n", .{ symbol, qty });

    // Logout: sends 35=5 and waits for server's Logout response.
    try client.logout(io);
    std.debug.print("client: sent Logout, recv Logout\n", .{});
}
