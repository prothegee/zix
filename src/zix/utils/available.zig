//! ZIX utils available
//!
//! ### file: src/zix/utils/available.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Check what is available on the machine.
//! 
//! ### note:
//! 
//! n/a
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

// --------------------------------------------------------- //
// Public:

/// Check if a network port is available.
///
/// Note:
/// - The check binds the address, so it answers for this process and machine.
/// - A busy port, a bad address, or a listen failure all answer false.
///
/// Param:
/// io - std.Io (the io the listen runs on)
/// ip - []const u8 (address text, for example "127.0.0.1")
/// port - u16 (port to test, 0 asks the system for a free port)
/// mode - std.Io.net.Socket.Mode (socket mode)
/// protocol - std.Io.net.Protocol (socket protocol)
///
/// Return:
/// - bool (true when the address could be bound)
pub fn networkPort(
    io: std.Io,
    ip: []const u8,
    port: u16,
    mode: std.Io.net.Socket.Mode,
    protocol: std.Io.net.Protocol,
) bool {
    var address = std.Io.net.IpAddress.resolve(io, ip, port) catch |err| switch (err) {
        else => return false,
    };

    var network = address.listen(io, .{
        .mode = mode,
        .protocol = protocol,
    }) catch |err| switch (err) {
        else => return false,
    };
    defer network.deinit(io);

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: available, reports a free port as available" {
    try std.testing.expect(networkPort(std.testing.io, "127.0.0.1", 0, .stream, .tcp));
}

test "zix utils: available, reports a bound port as unavailable" {
    const io = std.testing.io;

    var address = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", 0);
    var network = try address.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer network.deinit(io);

    const port = network.socket.address.getPort();

    try std.testing.expect(!networkPort(io, "127.0.0.1", port, .stream, .tcp));
}

test "zix utils: available, reports an invalid address as unavailable" {
    try std.testing.expect(!networkPort(std.testing.io, "not-an-ip", 0, .stream, .tcp));
    try std.testing.expect(!networkPort(std.testing.io, "", 0, .stream, .tcp));
}

