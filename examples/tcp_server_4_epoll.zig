const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9303;
const DISPATCH_MODEL: zix.Tcp.DispatchModel = .EPOLL;
const WORKERS: usize = 0; // ignored by .EPOLL (single event loop thread handles accept)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "tcp";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

// Note:
// On Linux, .EPOLL runs natively: a single epoll accept loop pushes accepted
// fds to an FdQueue. Pool workers pop and hold each connection for its full
// lifetime. TCP connections are stream-based — the handler loops until EOF,
// so one-thread-per-connection maps naturally to this model.
// On non-Linux targets, .EPOLL falls back to .POOL automatically (with a
// debug print). Use tcp_server_2_pool.zig to set POOL explicitly instead.

// --------------------------------------------------------- //

// Each pool thread calls this handler synchronously for each accepted connection.
// The handler owns stream and must close it before returning.
//
// Frame format (matches zix.Tcp.Client): [u32 big-endian len][payload]
//
// Client usage: zig build example-tcp_client -- --port 9303
pub fn myHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var rbuf: [4096 + 4]u8 = undefined;
    var wbuf: [4096 + 4]u8 = undefined;
    var payload_buf: [4096]u8 = undefined;

    var rdr = stream.reader(io, &rbuf);
    var wtr = stream.writer(io, &wbuf);

    while (true) {
        const len = rdr.interface.takeVarInt(u32, .big, 4) catch return;
        if (len == 0 or len > payload_buf.len) return;

        rdr.interface.readSliceAll(payload_buf[0..len]) catch return;
        std.debug.print("recv ({d} bytes): {s}\n", .{ len, payload_buf[0..len] });

        const reply = "Hello from zix TCP Server";
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(reply.len), .big);
        wtr.interface.writeAll(&hdr) catch return;
        wtr.interface.writeAll(reply) catch return;
        wtr.interface.flush() catch return;
    }
}

// --------------------------------------------------------- //

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

    var server = try zix.Tcp.Server.initArgs(.{
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
        // .logger = &logger, // uncomment to wire logger (TCP lifecycle + conn logging)
    }, process.minimal.args);
    defer server.deinit();

    try server.runWith(process.io, myHandler);
}
