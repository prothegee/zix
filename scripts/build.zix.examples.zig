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
//! n/a
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
        "example-http1_basic",
        "examples/http1_basic.zig",
        "http1",
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

    // const group_tcp = b.step("example-tcp", "ZIX: Build all tcp examples");
    // const group_fix = b.step("example-fix", "ZIX: Build all fix examples");
    const group_http1 = b.step("example-http1", "ZIX: Build all http1 examples");
    // const group_http2 = b.step("example-http2", "ZIX: Build all http2 examples");
    // const group_grpc = b.step("example-grpc", "ZIX: Build all grpc examples");
    // const group_udp = b.step("example-udp", "ZIX: Build all udp examples");
    // const group_http3 = b.step("example-http3", "ZIX: Build all http3 examples");
    // const group_webrtc = b.step("example-webrtc", "ZIX: Build all webrtc examples");
    // const group_uds = b.step("example-uds", "ZIX: Build all uds examples");
    // const group_tls = b.step("example-tls", "ZIX: Build all tls examples");
    // const group_channel = b.step("example-channel", "ZIX: Build all channel examples");

    // step.dependOn(group_tcp);
    // step.dependOn(group_fix);
    step.dependOn(group_http1);
    // step.dependOn(group_http2);
    // step.dependOn(group_grpc);
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
                "zix-{s}-{s}-{s}",
                .{ pair[0], triplet, mode },
            ),
            .root_module = exec_module,
        });

        const group = if (comptime std.mem.eql(u8, pair[2], "http1"))
            group_http1
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
