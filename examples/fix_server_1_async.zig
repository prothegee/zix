const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9500;
const COMP_ID: []const u8 = "ZIX";
const DISPATCH_MODEL: zix.Fix.DispatchModel = .ASYNC;
const WORKERS: usize = 0; // ignored by .ASYNC (always 1 accept thread)
const POOL_SIZE: usize = 0; // ignored by .ASYNC

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "fix";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

// Connects:
//   zig run rnd/fix_poc_client.zig -- --port 9500 --target ZIX

pub fn main(process: std.process.Init) !void {
    // Uncomment this to add logger (console only — no save_path means no file output):
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .console           = .ALWAYS,
    //     .console_min_level = .INFO,
    // });
    // defer logger.deinit();

    // Uncomment this to add logger with file output (createLogDir must run first):
    // createLogDir(process.io);
    // var logger = try zix.Logger.init(std.heap.smp_allocator, .{
    //     .save_path      = LOG_DIR,
    //     .save_file      = LOG_FILE,
    //     .save_min_level = .INFO,
    //     .console        = .ALWAYS,
    // });
    // defer logger.deinit();

    var server = try zix.Fix.Server.init(.{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .comp_id = COMP_ID,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        // .logger = &logger, // uncomment to wire logger (FIX lifecycle + session logging)
    });
    defer server.deinit();

    try server.run();
}
