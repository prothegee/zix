// Runner for http_static and http1_static examples.
// Spawns the server (which creates public/ and public/secret/), writes the test
// text file into public/secret/, then GETs /secret/<filename>?sec=abc123.
//
// Invoked by `zig build test-runner-http-static` or test-runner-http1-static.
// argv[1]: server binary path
// argv[2]: label
// argv[3]: port
// argv[4]: filename (e.g. "http_text_file.txt")
// argv[5]: file content

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");

const SEC_VAL: []const u8 = "abc123";
const WAIT_MS: u64 = 5000;

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) void {
    var arg_iter = std.process.Args.Iterator.init(process.minimal.args);
    _ = arg_iter.skip();
    const server_path = arg_iter.next() orelse {
        std.debug.print("FAIL: missing server path\n", .{});
        std.process.exit(1);
    };
    const label = arg_iter.next() orelse {
        std.debug.print("FAIL: missing label\n", .{});
        std.process.exit(1);
    };
    const port_str = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing port\n", .{label});
        std.process.exit(1);
    };
    const filename = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing filename\n", .{label});
        std.process.exit(1);
    };
    const file_content = arg_iter.next() orelse {
        std.debug.print("FAIL {s}: missing file content\n", .{label});
        std.process.exit(1);
    };

    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        std.debug.print("FAIL {s}: invalid port\n", .{label});
        std.process.exit(1);
    };

    run(process.io, server_path, port, filename, file_content) catch |err| {
        std.debug.print("FAIL {s}: {}\n", .{ label, err });
        std.process.exit(1);
    };
    std.debug.print("PASS {s}\n", .{label});
}

fn run(
    io: std.Io,
    server_path: []const u8,
    port: u16,
    filename: []const u8,
    file_content: []const u8,
) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    // Wait for the server to start and create the public/secret/ dir.
    try common.waitForTcpPort(io, port, WAIT_MS);

    var file_path_buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "public/secret/{s}", .{filename});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = file_content });

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "http://127.0.0.1:{d}/secret/{s}?sec={s}",
        .{ port, filename, SEC_VAL },
    );

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
}
