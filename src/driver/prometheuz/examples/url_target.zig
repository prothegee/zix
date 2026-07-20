//! prometheuz example: build a ScrapeConfig from a target URL
//! (parseScrapeUrl) instead of a Config struct, then scrape once.
//!
//! Note:
//! - basic_scrape.zig shows the same scrape from a Config struct directly.
//! - Needs the node-exporter container on 127.0.0.1:19100
//!   (`zig build test-runner` owns the lifecycle).

const std = @import("std");
const prometheuz = @import("prometheuz");

const TARGET_URL: []const u8 = "http://127.0.0.1:19100/metrics";

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = try prometheuz.parseScrapeUrl(TARGET_URL);

    var snapshot = try prometheuz.scrapeOnce(allocator, process.io, config);
    defer snapshot.deinit();

    std.debug.print("target: {s}:{d}{s}\n", .{ config.ip, config.port, config.path });
    std.debug.print("scrape up: {}\n", .{snapshot.up});
    std.debug.print("samples: {d}\n", .{snapshot.samples.len});

    std.debug.print("done\n", .{});
}
