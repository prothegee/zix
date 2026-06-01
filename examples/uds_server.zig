// uds_server.zig: UDS data provider (Process A)
//
// Listens on /tmp/zix.sock. For each received frame the server replies
// with an incrementing counter so the HTTP frontend sees real data changes.
//
// Frame format (both directions):
//   [u32 payload_len, 4 bytes, native LE] [payload bytes]
//
// Run Process A first:
// zig build example-uds_server && ./zig-out/bin/example-uds_server
//
// Then Process B in a second terminal:
// zig build example-uds_http && ./zig-out/bin/example-uds_http
// curl http://localhost:9200/data
// curl -N http://localhost:9200/stream

const std = @import("std");
const zix = @import("zix");

const SOCK_PATH: []const u8 = "/tmp/zix.sock";

// Logger config — uncomment this section to add logger
// const LOG_DIR: []const u8  = "./logs";
// const LOG_FILE: []const u8 = "uds";

// fn createLogDir(io: std.Io) void {
//     std.Io.Dir.cwd().createDirPath(io, LOG_DIR) catch {};
// }

// --------------------------------------------------------- //

// Shared counter incremented per frame across all connections.
// Atomic so concurrent connection tasks see consistent progression.
var g_counter = std.atomic.Value(u64).init(0);

// Custom handler: reads any frame ("get" by convention), responds with counter.
// The counter increments for every frame received regardless of content.
fn dataHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var rbuf: [256]u8 = undefined;
    var wbuf: [64]u8 = undefined;
    var payload_buf: [256]u8 = undefined;

    var rdr = stream.reader(io, &rbuf);
    var wtr = stream.writer(io, &wbuf);

    while (true) {
        // Read 4-byte length header (any content, treated as "get" request)
        var hdr: [4]u8 = undefined;
        var n: usize = 0;
        while (n < 4) {
            const got = rdr.interface.readSliceShort(hdr[n..]) catch return;
            if (got == 0) return;
            n += got;
        }

        const len = std.mem.readInt(u32, &hdr, .little);
        if (len > payload_buf.len) return;

        // Read and discard payload (any request content accepted)
        n = 0;
        while (n < len) {
            const got = rdr.interface.readSliceShort(payload_buf[n..len]) catch return;
            if (got == 0) return;
            n += got;
        }

        // Respond with the current counter as a decimal string
        const count = g_counter.fetchAdd(1, .monotonic);
        var resp_buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf, "{d}", .{count}) catch return;

        var resp_hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &resp_hdr, @intCast(resp.len), .little);
        wtr.interface.writeAll(&resp_hdr) catch return;
        wtr.interface.writeAll(resp) catch return;
        wtr.interface.flush() catch return;

        std.debug.print("uds_server: sent count={d}\n", .{count});
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

    var server = try zix.Uds.Server.init(.{
        .path = SOCK_PATH,
        .allocator = std.heap.smp_allocator,
        // .logger = &logger, // uncomment to wire logger (UDS lifecycle logging)
    });
    defer server.deinit();

    try server.run(process.io, dataHandler);
}
