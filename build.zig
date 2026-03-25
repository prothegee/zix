const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --------------------------------------------------------- //

    const mod = b.addModule("zix", .{
        .root_source_file = b.path("src/zix.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");

    const mod_tests = b.addTest(.{
        .root_module = mod
    });

    // --------------------------------------------------------- //

    const run_lib_tests = b.addRunArtifact(mod_tests);

    test_step.dependOn(&run_lib_tests.step);
}

