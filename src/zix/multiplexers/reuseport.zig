//! ZIX multiplexers reuseport
//!
//! ### file: src/zix/multiplexers/reuseport.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! SO_ATTACH_REUSEPORT_CBPF steering for the per-worker listeners of the
//! .EPOLL and .URING models: a new connection goes to the listener at index
//! (receiving CPU mod group size).
//!
//! ### note:
//!
//! - Classic BPF through setsockopt: no bpf(2) syscall and no privilege, so
//!   it also works in containers that block eBPF.
//! - Attaching through one member installs the program for the whole group.
//!   The listeners must join the group in worker order, so index i is
//!   worker i.
//! - A kernel without the option (before 4.5) keeps the default 4-tuple hash.
//!   Placement stays correct, only the CPU affinity is lost.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

/// Instruction class: load into the accumulator.
const BPF_LD: u16 = 0x00;
/// Instruction class: arithmetic on the accumulator.
const BPF_ALU: u16 = 0x04;
/// Instruction class: return.
const BPF_RET: u16 = 0x06;
/// Load size: 32-bit word.
const BPF_W: u16 = 0x00;
/// Load mode: absolute offset (here the ancillary data space).
const BPF_ABS: u16 = 0x20;
/// ALU op: modulo by the constant operand.
const BPF_MOD: u16 = 0x90;
/// Operand source: the constant k.
const BPF_K: u16 = 0x00;
/// Return source: the accumulator.
const BPF_A: u16 = 0x10;

/// Base of the classic BPF ancillary data space (SKF_AD_OFF).
const SKF_AD_OFF: i32 = -0x1000;
/// Ancillary field: the CPU handling this packet (SKF_AD_CPU).
const SKF_AD_CPU: i32 = 36;

/// setsockopt option: attach a classic BPF REUSEPORT group selector.
const SO_ATTACH_REUSEPORT_CBPF: u32 = 51;

/// One classic BPF instruction (struct sock_filter).
const SockFilter = extern struct {
    code: u16,
    jt: u8 = 0,
    jf: u8 = 0,
    k: u32,
};

/// The program descriptor passed to setsockopt (struct sock_fprog).
const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

/// The steering program: ld cpu, mod #group_size, ret A.
///
/// Note:
/// - The modulo keeps the index in range when a packet lands on a CPU past
///   the worker count.
fn steeringProgram(group_size: u32) [3]SockFilter {
    return .{
        .{
            .code = BPF_LD | BPF_W | BPF_ABS,
            .k = @bitCast(SKF_AD_OFF + SKF_AD_CPU),
        },
        .{
            .code = BPF_ALU | BPF_MOD | BPF_K,
            .k = group_size,
        },
        .{
            .code = BPF_RET | BPF_A,
            .k = 0,
        },
    };
}

// --------------------------------------------------------- //
// Public:

/// Attach the CPU steering program to a REUSEPORT group through one member.
///
/// Note:
/// - Call after every listener of the group is bound.
///
/// Param:
/// fd - std.posix.fd_t (any listener of the group)
/// group_size - usize (listener count of the group)
///
/// Return:
/// - true when the group steers by receiving CPU
/// - false when the group is empty, the platform is not Linux, or the
///   kernel refused it (the group keeps the default hash)
pub fn attachCpuSteering(fd: std.posix.fd_t, group_size: usize) bool {
    if (comptime builtin.os.tag != .linux) return false;
    if (group_size == 0) return false;

    const size: u32 = @intCast(@min(group_size, std.math.maxInt(u32)));
    const prog = steeringProgram(size);
    const fprog: SockFprog = .{
        .len = prog.len,
        .filter = &prog,
    };

    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_ATTACH_REUSEPORT_CBPF,
        std.mem.asBytes(&fprog),
    ) catch |err| switch (err) {
        else => return false,
    };

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix multiplexers: reuseport, steeringProgram loads the cpu" {
    const prog = steeringProgram(6);
    const want: u32 = @bitCast(SKF_AD_OFF + SKF_AD_CPU);

    try std.testing.expectEqual(BPF_LD | BPF_W | BPF_ABS, prog[0].code);
    try std.testing.expectEqual(want, prog[0].k);
}

test "zix multiplexers: reuseport, steeringProgram takes the group size modulo" {
    const prog = steeringProgram(6);

    try std.testing.expectEqual(BPF_ALU | BPF_MOD | BPF_K, prog[1].code);
    try std.testing.expectEqual(@as(u32, 6), prog[1].k);
}

test "zix multiplexers: reuseport, steeringProgram returns the accumulator" {
    const prog = steeringProgram(6);

    try std.testing.expectEqual(BPF_RET | BPF_A, prog[2].code);
}

test "zix multiplexers: reuseport, SockFilter matches the C layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SockFilter));
}

test "zix multiplexers: reuseport, SockFprog matches the C layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(SockFprog, "len"));
    try std.testing.expectEqual(@sizeOf(usize), @offsetOf(SockFprog, "filter"));
}

test "zix multiplexers: reuseport, an empty group cannot steer" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    try std.testing.expect(!attachCpuSteering(-1, 0));
}

test "zix multiplexers: reuseport, a reuseport listener takes the program" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(std.testing.io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 8,
    });
    defer listener.deinit(std.testing.io);

    try std.testing.expect(attachCpuSteering(listener.socket.handle, 4));
}

