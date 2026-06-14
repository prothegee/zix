const std = @import("std");

pub fn build(b: *std.Build) void {
    const zon = @import("build.zig.zon");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zix = b.addModule("zix", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------------------------------------- //

    const zon_options = b.addOptions();
    zon_options.addOption([]const u8, "user_agent", zon.user_agent);
    zix.addOptions("zon_options", zon_options);

    // --------------------------------------------------------- //

    @import("zix-build-tests.zig").addSteps(b, target, optimize, zix);
    @import("zix-build-examples.zig").addSteps(b, target, optimize, zix);
    @import("zix-build-test_runner.zig").addSteps(b, target, optimize, zix);
}
