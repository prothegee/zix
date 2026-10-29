const std = @import("std");

fn doSomething() !void {
    std.debug.print("Do something done.\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var future = io.async(doSomething, .{});
    defer _ = future.cancel(io) catch unreachable;

    // // uncomment below to doSomething first
    // // otherwise doSomething happen when out of scope
    // _ = try future.await(io);

    std.debug.print("Do this first\n", .{});
}

