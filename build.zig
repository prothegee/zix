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

    // Zix cleanup artifacts
    const clean_cmd = b.addSystemCommand(&.{
        "zig", "run", "scripts/cleanup.zig"
    });
    const clean_step = b.step("cleanup", "ZIX: Cleanup artifacts.");
    clean_step.dependOn(&clean_cmd.step);

    // Zix unit & edge test
    const zix_unit_and_edge_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/zix/test.zig"),
    });
    zix_unit_and_edge_test_mod.addImport("zix", zix);

    const zix_unit_and_edge_test = b.addTest(.{
        .root_module = zix_unit_and_edge_test_mod
    });

    const zix_unit_and_edge_test_artifact = b.addRunArtifact(zix_unit_and_edge_test);

    // Tests declared inside src/zix. A dependency module's tests are not part
    // of the root module's test run, so the module is its own test root.
    const zix_module_test = b.addTest(.{
        .root_module = zix,
    });
    const zix_module_test_artifact = b.addRunArtifact(zix_module_test);

    const zix_unit_and_edge_test_step =
        b.step("zix-unit_edge-test", "ZIX: Run unit & edge tests.");
    zix_unit_and_edge_test_step.dependOn(&zix_unit_and_edge_test_artifact.step);
    zix_unit_and_edge_test_step.dependOn(&zix_module_test_artifact.step);

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

    // --------------------------------------------------------- //
    // RESERVED
}

