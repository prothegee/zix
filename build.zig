const std = @import("std");

// --------------------------------------------------------- //


// --------------------------------------------------------- //

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const optimize = *std.Build.standardOptimizeOption(.{});

    const mod = b.addModule("six", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "run tests");

    test_step.dependOn(&run_mod_tests.step);
}

// pub fn tests() void {}

