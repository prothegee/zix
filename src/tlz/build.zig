//! TLZ build root
//!
//! ### file: src/tlz/build.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Build steps for the tlz package: the module, the test steps, and the examples.
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
const builtin = @import("builtin");

// --------------------------------------------------------- //
// Private:

const ALLOWED_ZIG = struct {
    pub const MAJOR: usize = 0;
    pub const MINOR: usize = 17;
};

/// Example names, one per file under `examples/`.
const EXAMPLES = [_][]const u8{
    "tls13_loopback",
    "tls12_loopback",
    "dtls_loopback",
    "cert_verify",
    "tls13_echo_server",
    "tls13_echo_client",
    "bench_rsa",
    "bench_ecdsa_p256",
    "bench_ed25519",
    "bench_record",
};

/// Behaviour tier suites, one per file under `tests/behaviour/`.
const BEHAVIOUR_SUITES = [_][]const u8{};

/// The OpenSSL headers the binding needs, written into the build cache and
/// translated once, so no C header file is tracked in the package.
const OPENSSL_HEADER =
    \\#include <openssl/ssl.h>
    \\#include <openssl/err.h>
    \\#include <openssl/x509v3.h>
    \\
;

/// Header locations checked when `pkg-config` is missing or does not know OpenSSL.
const OPENSSL_HEADER_PATHS = [_][]const u8{
    "/usr/include/openssl/ssl.h",
    "/usr/local/include/openssl/ssl.h",
};

fn ensureSupportedZig() void {
    const zig = builtin.zig_version;

    if (zig.major == ALLOWED_ZIG.MAJOR and zig.minor == ALLOWED_ZIG.MINOR) return;

    @compileError(std.fmt.comptimePrint(
        "tlz build requires Zig {d}.{d}.\n" ++
            "Found {d}.{d}.{d}.",
        .{
            ALLOWED_ZIG.MAJOR,
            ALLOWED_ZIG.MINOR,
            zig.major,
            zig.minor,
            zig.patch,
        },
    ));
}

/// Ask `pkg-config` whether the host has OpenSSL.
///
/// Return:
/// - true when `pkg-config --exists openssl` exits with 0
/// - false when it fails, exits non zero, or cannot be spawned
fn pkgConfigHasOpenssl(b: *std.Build) bool {
    const result = b.runFallible(&.{
        "pkg-config",
        "--exists",
        "openssl",
    }, .{
        .stderr_behavior = .ignore,
    });

    return switch (result) {
        .success => true,
        .spawn_failed, .bad_exit_code, .crashed => false,
    };
}

/// Look for the OpenSSL header in the standard include directories.
///
/// Return:
/// - true when one of `OPENSSL_HEADER_PATHS` is readable
/// - false when none is
fn headerHasOpenssl(b: *std.Build) bool {
    for (OPENSSL_HEADER_PATHS) |path| {
        std.Io.Dir.accessAbsolute(b.graph.io, path, .{
            .read = true,
        }) catch |err| switch (err) {
            // Best effort probe: any failure means this path does not count.
            else => continue,
        };

        return true;
    }

    return false;
}

/// Add one test run per suite file to `step`.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target every suite compiles for)
/// optimize - std.builtin.OptimizeMode (the optimize mode every suite compiles with)
/// tlz - *std.Build.Module (the package under test, imported as "tlz")
/// step - *std.Build.Step (the tier step that runs every suite)
/// sources - []const []const u8 (the suite paths)
///
/// Return:
/// - void
fn addSuites(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tlz: *std.Build.Module,
    step: *std.Build.Step,
    sources: []const []const u8,
) void {
    for (sources) |source| {
        const suite_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(source),
        });
        suite_module.addImport("tlz", tlz);

        const suite_tests = b.addTest(.{
            .root_module = suite_module,
        });
        const suite_run = b.addRunArtifact(suite_tests);

        step.dependOn(&suite_run.step);
    }
}

/// Add one install step per example, plus the `examples` step that builds them all.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target every example compiles for)
/// optimize - std.builtin.OptimizeMode (the optimize mode every example compiles with)
/// tlz - *std.Build.Module (the package, imported as "tlz")
///
/// Return:
/// - void
fn addExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tlz: *std.Build.Module,
) void {
    const triplet = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });

    const mode = switch (optimize) {
        .debug => "debug",
        .safe => "safe",
        .fast => "fast",
        .small => "small",
    };

    const all_step = b.step("examples", "TLZ: Build all examples.");

    for (EXAMPLES) |name| {
        const example_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
        });
        example_module.addImport("tlz", tlz);

        const example_exe = b.addExecutable(.{
            .name = b.fmt("tlz-example-{s}-{s}-{s}", .{
                name,
                triplet,
                mode,
            }),
            .root_module = example_module,
        });
        const example_install = b.addInstallArtifact(example_exe, .{});

        const single_step = b.step(
            b.fmt("example-{s}", .{name}),
            b.fmt("TLZ: Build the {s} example.", .{name}),
        );
        single_step.dependOn(&example_install.step);
        all_step.dependOn(&example_install.step);
    }
}

// --------------------------------------------------------- //
// Public:

/// Detect OpenSSL on the host: `pkg-config` first, then the standard header paths.
///
/// Note:
/// - A cross target is never detected, the host libraries do not apply to it.
/// - The version floor is checked at compile time in `src/openssl/c.zig`.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target the package compiles for)
///
/// Return:
/// - true when OpenSSL is found for a native target
/// - false otherwise
pub fn detectOpenssl(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    if (!target.query.isNative()) return false;

    return pkgConfigHasOpenssl(b) or headerHasOpenssl(b);
}

/// Give `module` the translated OpenSSL headers (imported as "openssl_c") and link
/// libssl, libcrypto, and libc.
///
/// Note:
/// - Call it only when `detectOpenssl` returned true.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target the headers are translated for)
/// optimize - std.builtin.OptimizeMode (the optimize mode of the translated module)
/// module - *std.Build.Module (the module that compiles the openssl subtree)
///
/// Return:
/// - void
pub fn linkOpenssl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
) void {
    const header_files = b.addWriteFiles();
    const header = header_files.add("openssl_c.h", OPENSSL_HEADER);

    const translate = b.addTranslateC(.{
        .root_source_file = header,
        .target = target,
        .optimize = optimize,
    });

    module.addImport("openssl_c", translate.createModule());
    module.link_libc = true;
    module.linkSystemLibrary("ssl", .{});
    module.linkSystemLibrary("crypto", .{});
}

pub fn build(b: *std.Build) void {
    ensureSupportedZig();

    const zon = @import("build.zig.zon");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tlz_options = b.addOptions();
    tlz_options.addOption(usize, "version_major", zon.semver.major);
    tlz_options.addOption(usize, "version_minor", zon.semver.minor);
    tlz_options.addOption(usize, "version_patch", zon.semver.patch);

    const openssl = detectOpenssl(b, target);
    tlz_options.addOption(bool, "openssl", openssl);

    const tlz = b.addModule("tlz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/lib.zig"),
    });
    tlz.addOptions("tlz_options", tlz_options);
    if (openssl) linkOpenssl(b, target, optimize, tlz);

    // Unit and edge: the in-file tests under src/, collected through src/test.zig
    const unit_edge_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/test.zig"),
    });
    unit_edge_mod.addOptions("tlz_options", tlz_options);
    if (openssl) linkOpenssl(b, target, optimize, unit_edge_mod);

    const unit_edge_tests = b.addTest(.{
        .root_module = unit_edge_mod,
    });
    const unit_edge_run = b.addRunArtifact(unit_edge_tests);

    const unit_edge_step = b.step("unit_edge-test", "TLZ: Run unit & edge tests.");
    unit_edge_step.dependOn(&unit_edge_run.step);

    // Behaviour: one test binary per suite file
    const behaviour_step = b.step("behaviour-test", "TLZ: Run behaviour tests.");
    addSuites(b, target, optimize, tlz, behaviour_step, &BEHAVIOUR_SUITES);

    const all_step = b.step("all-test", "TLZ: Run unit, edge, and behaviour tests.");
    all_step.dependOn(unit_edge_step);
    all_step.dependOn(behaviour_step);

    // Examples
    addExamples(b, target, optimize, tlz);
}

