//! postgrez example: transactions, explicit core and callback sugar.
//!
//! Note:
//! - Explicit: begin, defer rollback, commit (rollback after commit is a
//!   no-op). Callback: conn.transaction(fn, args) rolls back on any error.
//! - Needs the PostgreSQL 18 container on 127.0.0.1:54180.

const std = @import("std");
const postgrez = @import("postgrez");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 54180;
const USER: []const u8 = "role_scram";
const PASSWORD: []const u8 = "postgrez_scram_pw";
const DATABASE: []const u8 = "postgrez_test";

// --------------------------------------------------------- //

const Total = struct {
    total: i64,
};

fn transfer(tx: *postgrez.Tx, amount: i64) !void {
    _ = try tx.exec("INSERT INTO ledger (amount) VALUES ($1)", .{amount});
    _ = try tx.exec("INSERT INTO ledger (amount) VALUES ($1)", .{-amount});
}

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const conn = try postgrez.Conn.connect(allocator, process.io, .{
        .ip = IP,
        .port = PORT,
        .user = USER,
        .password = PASSWORD,
        .database = DATABASE,
    });
    defer conn.deinit();

    _ = try conn.exec("TRUNCATE ledger", .{});

    // rolled back: invisible afterwards
    {
        var tx = try conn.begin();
        _ = try tx.exec("INSERT INTO ledger (amount) VALUES ($1)", .{@as(i64, 999)});
        tx.rollback();
    }
    const after_rollback = try conn.queryRow(Total, "SELECT count(*)::int8 AS total FROM ledger", .{});
    std.debug.print("rows after rollback: {d}\n", .{after_rollback.?.total});

    // committed: visible
    {
        var tx = try conn.begin();
        defer tx.rollback();
        _ = try tx.exec("INSERT INTO ledger (amount) VALUES ($1)", .{@as(i64, 100)});

        try tx.commit();
    }

    // callback sugar
    try conn.transaction(transfer, .{@as(i64, 40)});

    const sum = try conn.queryRow(Total, "SELECT coalesce(sum(amount), 0)::int8 AS total FROM ledger", .{});
    std.debug.print("ledger sum: {d}\n", .{sum.?.total});

    std.debug.print("done\n", .{});
}
