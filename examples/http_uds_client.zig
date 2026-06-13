//! http_uds_client.zig: HTTP/1.1 over Unix domain socket example.
//!
//! Uses zix.Http.Client.getUds() to query the Docker daemon API
//! at /var/run/docker.sock. Requires Docker running on the host.
//!
//! The same API works against any server that speaks HTTP/1.1 over a
//! Unix socket (containerd, systemd socket activation, etc.).
//!
//! Run:
//! zig build example-http_uds_client && ./zig-out/bin/example-http_uds_client

const std = @import("std");
const zix = @import("zix");

const DOCKER_SOCK: []const u8 = "/var/run/docker.sock";

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = process.io,
        .max_response_body = 1024 * 1024,
    });
    defer client.deinit();

    // GET /_ping: liveness check, responds "OK" with status 200.
    {
        var resp = client.getUds(DOCKER_SOCK, "/_ping", .{}) catch |err| {
            std.debug.print("uds: /_ping error: {} (is Docker running?)\n", .{err});
            return;
        };
        defer resp.deinit();
        std.debug.print("uds: GET /_ping  status={d}  body={s}\n", .{ resp.status(), resp.body() });
    }

    // GET /version: Docker version JSON.
    {
        var resp = client.getUds(DOCKER_SOCK, "/version", .{}) catch |err| {
            std.debug.print("uds: /version error: {}\n", .{err});
            return;
        };
        defer resp.deinit();
        const body = resp.body();
        const preview = body[0..@min(body.len, 256)];
        std.debug.print("uds: GET /version  status={d}  body(first 256)={s}...\n", .{ resp.status(), preview });
    }
}
