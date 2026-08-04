const std = @import("std");

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zix: *std.Build.Module,
) void {
    // zixer is a standalone executable rooted at src/zixer, it links against the
    // zix module and never joins the library surface. The installed binary
    // carries the target triple (zixer-<arch>-<os>) like the examples, so
    // building several targets in a row never overwrites a prior target's
    // binary in zig-out/bin. The step name stays `zixer`.
    const triple = b.fmt("{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });

    const zixer_mod = b.createModule(.{
        .root_source_file = b.path("src/zixer/zixer.zig"),
        .target = target,
        .optimize = optimize,
    });
    zixer_mod.addImport("zix", zix);

    const exe = b.addExecutable(.{
        .name = b.fmt("zixer-{s}", .{triple}),
        .root_module = zixer_mod,
    });

    const install = b.addInstallArtifact(exe, .{});
    const build_step = b.step("zixer", "Build the zixer proxy gateway executable (run it from zig-out/bin)");
    build_step.dependOn(&install.step);
}
