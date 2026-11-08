// ZIX build root
//!
//! ### file: build.zig
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
const tools = @import("scripts/build.tools.zig");
const examples = @import("scripts/build.zix.examples.zig");
const VersionInfo = tools.VersionInfo;

// --------------------------------------------------------- //

pub fn build(b: *std.Build) void {
    tools.ensureSupportedZig();
    tools.checkRequiredDirs(b) catch return;
    tools.checkRequiredFiles(b) catch return;

    const zon = @import("build.zig.zon");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zix = b.addModule("zix", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/zix/lib.zig"),
    });

    const zix_options = b.addOptions();
    const zix_version_info = VersionInfo{
        .major = zon.semver.major,
        .minor = zon.semver.minor,
        .patch = zon.semver.patch,
        .release_candidate = zon.semver.release_candidate,
    };

    zix_options.addOption([]const u8, "user_agent", zon.user_agent);
    zix_options.addOption([]const u8, "version", zon.version);
    zix_options.addOption(VersionInfo, "zix_version_info", zix_version_info);
    zix.addOptions("zix_options", zix_options);

    // Jzon module: the same package src/jzon builds on its own, used as `zix.jzon`
    const jzon_zon = @import("src/jzon/build.zig.zon");
    const jzon_options = b.addOptions();
    jzon_options.addOption(usize, "version_major", jzon_zon.semver.major);
    jzon_options.addOption(usize, "version_minor", jzon_zon.semver.minor);
    jzon_options.addOption(usize, "version_patch", jzon_zon.semver.patch);

    const jzon = b.addModule("jzon", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/jzon/src/lib.zig"),
    });
    jzon.addOptions("jzon_options", jzon_options);
    zix.addImport("jzon", jzon);

    // Zix cleanup artifacts
    const clean_cmd = b.addSystemCommand(&.{
        "zig", "run", "scripts/cleanup.zig"
    });
    const clean_step = b.step("cleanup", "ZIX: Cleanup artifacts project.");
    clean_step.dependOn(&clean_cmd.step);

    // Zix unit & edge test
    const zix_unit_and_edge_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/zix/test.zig"),
    });
    zix_unit_and_edge_test_mod.addOptions("zix_options", zix_options);
    zix_unit_and_edge_test_mod.addImport("jzon", jzon);

    const zix_unit_and_edge_test = b.addTest(.{
        .root_module = zix_unit_and_edge_test_mod
    });

    const zix_unit_and_edge_test_artifact = b.addRunArtifact(zix_unit_and_edge_test);

    const zix_unit_and_edge_test_step =
        b.step("zix-unit_edge-test", "ZIX: Run unit & edge tests.");
    zix_unit_and_edge_test_step.dependOn(&zix_unit_and_edge_test_artifact.step);

    // If no args, run zix-unit_edge-test
    // mean it only run `zig build`
    // TODO

    // Optional: Zix behaviour test
    // TODO

    // Optional: Zix integration test
    // TODO

    // Optional: Examples
    if (tools.diExists(b, "examples")) {
        examples
            .addSteps(b, target, optimize, zix);
    } else {
        std.log.info("zix build: examples dir not exists, skipping\n", .{});
    }

    // Jzon steps come after the zix steps, so `zig build -h` lists zix first.
    // Jzon unit & edge test, built in this graph like zix-unit_edge-test
    const jzon_unit_and_edge_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/jzon/src/test.zig"),
    });
    jzon_unit_and_edge_test_mod.addOptions("jzon_options", jzon_options);

    const jzon_unit_and_edge_test = b.addTest(.{
        .root_module = jzon_unit_and_edge_test_mod,
    });

    const jzon_unit_and_edge_test_artifact = b.addRunArtifact(jzon_unit_and_edge_test);

    const jzon_unit_and_edge_test_step =
        b.step("jzon-unit_edge-test", "JZON: Run unit & edge tests.");
    jzon_unit_and_edge_test_step.dependOn(&jzon_unit_and_edge_test_artifact.step);

    // Jzon package steps: each one runs `zig build <step>` inside src/jzon
    const jzon_steps = [_][3][]const u8{
        .{
            "jzon-test-behaviour",
            "test-behaviour",
            "JZON: Run behaviour tests.",
        },
        .{
            "jzon-test-all",
            "test-all",
            "JZON: Run unit, edge, and behaviour tests.",
        },
        .{
            "jzon-examples",
            "examples",
            "JZON: Build all examples into src/jzon/zig-out/bin.",
        },
    };

    for (jzon_steps) |entry| {
        const jzon_cmd = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            entry[1],
            b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        });
        jzon_cmd.setCwd(b.path("src/jzon"));

        const jzon_step = b.step(entry[0], entry[2]);
        jzon_step.dependOn(&jzon_cmd.step);
    }

    // --------------------------------------------------------- //
    // RESERVED
}

