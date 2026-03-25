const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zix = b.addModule("zix", .{
        .root_source_file = b.path("src/zix.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zix_tests = b.addTest(.{ .root_module = zix });
    const zix_tests_run = b.addRunArtifact(zix_tests);

    // --------------------------------------------------------- //

    const test_step = b.step("test", "Run tests");

    // --------------------------------------------------------- //

    test_step.dependOn(&zix_tests_run.step);
}

