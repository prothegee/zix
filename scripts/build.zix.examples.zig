//! ZIX script build examples
//!
//! ### file: scripts/build.zix.examples.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Build steps for the example binaries.
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

const EXAMPLES = .{
    // http1
    .{
        "zix-example-http1_basic",
        "examples/http1_basic.zig",
        "http1",
    },
    .{
        "zix-example-http1_json",
        "examples/http1_json.zig",
        "http1",
    },
    .{
        "zix-example-http1_params",
        "examples/http1_params.zig",
        "http1",
    },
    .{
        "zix-example-http1_paths",
        "examples/http1_paths.zig",
        "http1",
    },
    .{
        "zix-example-http1_logger",
        "examples/http1_logger.zig",
        "http1",
    },
    .{
        "zix-example-http1_xtra_headers",
        "examples/http1_xtra_headers.zig",
        "http1",
    },
    .{
        "zix-example-http1_middleware",
        "examples/http1_middleware.zig",
        "http1",
    },
    .{
        "zix-example-http1_query",
        "examples/http1_query.zig",
        "http1",
    },
    .{
        "zix-example-http1_timeout_resp",
        "examples/http1_timeout_resp.zig",
        "http1",
    },
    .{
        "zix-example-http1_manual_concurrent",
        "examples/http1_manual_concurrent.zig",
        "http1",
    },
    .{
        "zix-example-http1_sse",
        "examples/http1_sse.zig",
        "http1",
    },
    .{
        "zix-example-http1_cache",
        "examples/http1_cache.zig",
        "http1",
    },
    .{
        "zix-example-http1_compression",
        "examples/http1_compression.zig",
        "http1",
    },
    .{
        "zix-example-http1_static_cached",
        "examples/http1_static_cached.zig",
        "http1",
    },
    .{
        "zix-example-http1_static",
        "examples/http1_static.zig",
        "http1",
    },
    .{
        "zix-example-http1_websocket",
        "examples/http1_websocket.zig",
        "http1",
    },
    .{
        "zix-example-http1_upload",
        "examples/http1_upload.zig",
        "http1",
    },
    .{
        "zix-example-http1_jzon",
        "examples/http1_jzon.zig",
        "http1",
    },
    // http2 and grpc
    .{
        "zix-example-http2_basic",
        "examples/http2_basic.zig",
        "http2",
    },
    .{
        "zix-example-grpc_server",
        "examples/grpc_server.zig",
        "grpc",
    },
    .{
        "zix-example-grpc_location_server",
        "examples/grpc_location_server.zig",
        "grpc",
    },
    .{
        "zix-example-grpc_timeout",
        "examples/grpc_timeout.zig",
        "grpc",
    },
    .{
        "zix-example-grpc_multi_server",
        "examples/grpc_multi_server.zig",
        "grpc",
    },
    .{
        "zix-example-http2_logger",
        "examples/http2_logger.zig",
        "http2",
    },
    .{
        "zix-example-grpc_logger",
        "examples/grpc_logger.zig",
        "grpc",
    },
};

// --------------------------------------------------------- //

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
) void {
    const triplet =
        b.fmt(
            "{s}-{s}",
            .{
                @tagName(target.result.cpu.arch),
                @tagName(target.result.os.tag),
            }
        );

    const mode = switch (optimize) {
        .debug => "debug",
        .safe => "safe",
        .fast => "fast",
        .small => "small",
    };

    const step = b.step("zix-examples", "ZIX: Build all examples.");

    // const group_tcp = b.step("zix-example-tcp", "ZIX: Build all tcp examples");
    // const group_fix = b.step("example-fix", "ZIX: Build all fix examples");
    const group_http1 = b.step("zix-example-http1", "ZIX: Build all http1 examples");
    const group_http2 = b.step("zix-example-http2", "ZIX: Build all http2 examples");
    const group_grpc = b.step("zix-example-grpc", "ZIX: Build all grpc examples");
    // const group_udp = b.step("zix-example-udp", "ZIX: Build all udp examples");
    // const group_http3 = b.step("zix-example-http3", "ZIX: Build all http3 examples");
    // const group_webrtc = b.step("zix-example-webrtc", "ZIX: Build all webrtc examples");
    // const group_uds = b.step("zix-example-uds", "ZIX: Build all uds examples");
    // const group_tls = b.step("zix-example-tls", "ZIX: Build all tls examples");
    // const group_channel = b.step("zix-example-channel", "ZIX: Build all channel examples");

    // step.dependOn(group_tcp);
    // step.dependOn(group_fix);
    step.dependOn(group_http1);
    step.dependOn(group_http2);
    step.dependOn(group_grpc);
    // step.dependOn(group_udp);
    // step.dependOn(group_http3);
    // step.dependOn(group_webrtc);
    // step.dependOn(group_uds);
    // step.dependOn(group_tls);
    // step.dependOn(group_channel);

    inline for (EXAMPLES) |pair| {
        const exec_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(pair[1]),
        });
        exec_module.addImport("zix", zix);

        const exec = b.addExecutable(.{
            .name = b.fmt(
                "{s}-{s}-{s}",
                .{ pair[0], triplet, mode },
            ),
            .root_module = exec_module,
        });

        const group = if (comptime std.mem.eql(u8, pair[2], "http1"))
            group_http1
        else if (comptime std.mem.eql(u8, pair[2], "http2"))
            group_http2
        else if (comptime std.mem.eql(u8, pair[2], "grpc"))
            group_grpc
        // const group = if (comptime std.mem.eql(u8, pair[2], "tcp"))
        //     group_tcp
        // else if (comptime std.mem.eql(u8, pair[2], "fix"))
        //     group_fix
        // else if (comptime std.mem.eql(u8, pair[2], "http1"))
        //     group_http1
        // else if (comptime std.mem.eql(u8, pair[2], "http2"))
        //     group_http2
        // else if (comptime std.mem.eql(u8, pair[2], "grpc"))
        //     group_grpc
        // else if (comptime std.mem.eql(u8, pair[2], "udp"))
        //     group_udp
        // else if (comptime std.mem.eql(u8, pair[2], "http3"))
        //     group_http3
        // else if (comptime std.mem.eql(u8, pair[2], "webrtc"))
        //     group_webrtc
        // else if (comptime std.mem.eql(u8, pair[2], "uds"))
        //     group_uds
        // else if (comptime std.mem.eql(u8, pair[2], "tls"))
        //     group_tls
        // else if (comptime std.mem.eql(u8, pair[2], "channel"))
        //     group_channel
        else
            @compileError("unknown example group tag: " ++ pair[2]);

        const install = b.addInstallArtifact(exec, .{});
        group.dependOn(&install.step);

        const build = b.step(pair[0], "ZIX: Build " ++ pair[0]);
        build.dependOn(&install.step);
    }
}

