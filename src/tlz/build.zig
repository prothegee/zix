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
const OpensslProbe = @import("scripts/OpensslProbe.zig");

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

/// True when `path` (absolute, or relative to the working directory) exists.
fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch |err| switch (err) {
        // Best effort probe: any failure means the path does not count.
        else => return false,
    };

    return true;
}

/// Run the configure phase again when OpenSSL changes, instead of on every build.
///
/// Note:
/// - Found: watch its `opensslv.h` (an upgrade, downgrade, or removal changes it).
/// - Not found: watch the standard include directories that exist, so an install
///   (a new `openssl/` entry) is seen. None on a Windows host.
/// - A missing path is never watched: Zig would then configure on every build.
fn watchOpenssl(b: *std.Build, result: *const OpensslProbe) void {
    if (result.found()) {
        const header_path = result.versionHeaderPath(b.graph.arena) catch |err| switch (err) {
            // Best effort: without the path there is nothing to watch.
            error.Tlz_OpensslProbe_EnvDirInvalid, error.Tlz_OpensslProbe_OutOfMemory => return,
        } orelse return;

        if (pathExists(b, header_path)) b.dependOnFileContents(.{
            .cwd_relative = header_path,
        });
        return;
    }

    for (OpensslProbe.standardIncludeDirs(b.graph.host.result.os.tag)) |dir| {
        if (pathExists(b, dir)) b.dependOnDirectoryMetadata(.{
            .cwd_relative = dir,
        });
    }
}

/// The state text the build is configured with: "none", "unknown", or the version.
fn configuredState(b: *std.Build, openssl: ?OpensslProbe) []const u8 {
    const result = openssl orelse OpensslProbe.NOT_FOUND;
    const buf = b.graph.arena.alloc(u8, 32) catch |err| switch (err) {
        error.OutOfMemory => @panic("tlz build: out of memory while preparing the " ++
            "openssl-check argument"),
    };

    return result.stateText(buf);
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

/// Detect OpenSSL on the host (`OPENSSL_DIR`, then `pkg-config`, then the standard
/// include directories on a host that is not Windows). It logs one info line with
/// the result.
///
/// Note:
/// - A cross target is never detected, the host libraries do not apply to it.
/// - A version below 3.5 stops the build, even when no code picks `.OPENSSL`.
/// - An `OPENSSL_DIR` without OpenSSL headers stops the build.
/// - An unknown version keeps the binding: `src/openssl/c.zig` checks the floor
///   again at compile time.
/// - The configure phase runs again only when OpenSSL changes (see `watchOpenssl`).
///   `zig build openssl-check` reports a change the watch cannot see.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target the package compiles for)
///
/// Return:
/// - OpensslProbe when OpenSSL is found for a native target
/// - null otherwise
pub fn detectOpenssl(b: *std.Build, target: std.Build.ResolvedTarget) ?OpensslProbe {
    if (!target.query.isNative()) {
        std.log.info("tlz build: cross target, OpenSSL not probed, native only", .{});
        return null;
    }

    const result = OpensslProbe.probe(
        b.graph.arena,
        b.graph.io,
        &b.graph.environ_map,
        b.graph.host.result.os.tag,
    ) catch |err| switch (err) {
        error.Tlz_OpensslProbe_EnvDirInvalid => std.process.fatal(
            "tlz build: OPENSSL_DIR is set, but <dir>/include/openssl/ssl.h is missing",
            .{},
        ),
        error.Tlz_OpensslProbe_OutOfMemory => @panic("tlz build: out of memory while " ++
            "probing OpenSSL (joining a path or reading opensslv.h)"),
    };

    watchOpenssl(b, &result);

    if (!result.found()) {
        std.log.info("tlz build: OpenSSL not detected, native only", .{});
        return null;
    }

    const version = result.version orelse {
        std.log.info("tlz build: OpenSSL detected ({s}), version unknown, binding enabled " ++
            "(the floor is checked at compile time)", .{result.sourceName()});
        return result;
    };

    if (result.belowFloor()) {
        std.process.fatal("tlz build: OpenSSL {d}.{d}.{d} detected ({s}), below the " ++
            "supported {d}.{d}. Install OpenSSL {d}.{d} or newer (3.x), " ++
            "or 4.0 or newer (4.x).", .{
            version.major,
            version.minor,
            version.patch,
            result.sourceName(),
            OpensslProbe.OPENSSL_FLOOR.major,
            OpensslProbe.OPENSSL_FLOOR.minor,
            OpensslProbe.OPENSSL_FLOOR.major,
            OpensslProbe.OPENSSL_FLOOR.minor,
        });
    }

    std.log.info("tlz build: OpenSSL {d}.{d}.{d} detected ({s}), binding enabled " ++
        "({d}.x: {s})", .{
        version.major,
        version.minor,
        version.patch,
        result.sourceName(),
        version.major,
        result.hostCheckCall(),
    });

    return result;
}

/// Give `module` the translated OpenSSL headers (imported as "openssl_c") and link
/// libssl, libcrypto, and libc.
///
/// Note:
/// - Call it only with the result of `detectOpenssl`.
/// - The include directory found is passed to translate-c, so a non-standard
///   location (Homebrew, `OPENSSL_DIR`) compiles.
/// - Library names: `libssl` and `libcrypto` for an MSVC target, `ssl` and `crypto`
///   otherwise. The MSVC names are not verified on Windows yet.
///
/// Param:
/// b - *std.Build (the build graph)
/// target - std.Build.ResolvedTarget (the target the headers are translated for)
/// optimize - std.builtin.OptimizeMode (the optimize mode of the translated module)
/// module - *std.Build.Module (the module that compiles the openssl subtree)
/// openssl - *const OpensslProbe (where OpenSSL was found)
///
/// Return:
/// - void
pub fn linkOpenssl(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    openssl: *const OpensslProbe,
) void {
    const header_files = b.addWriteFiles();
    const header = header_files.add("openssl_c.h", OPENSSL_HEADER);

    const translate = b.addTranslateC(.{
        .root_source_file = header,
        .target = target,
        .optimize = optimize,
    });
    if (openssl.include_dir) |dir| translate.addIncludePath(.{
        .cwd_relative = dir,
    });
    if (openssl.lib_dir) |dir| module.addLibraryPath(.{
        .cwd_relative = dir,
    });

    const is_msvc = target.result.abi == .msvc;
    const link_options: std.Build.Module.LinkSystemLibraryOptions = .{
        // `OPENSSL_DIR` names the install: do not let pkg-config pick another one.
        .use_pkg_config = if (openssl.source == .ENV) .no else .yes,
    };

    module.addImport("openssl_c", translate.createModule());
    module.link_libc = true;
    module.linkSystemLibrary(if (is_msvc) "libssl" else "ssl", link_options);
    module.linkSystemLibrary(if (is_msvc) "libcrypto" else "crypto", link_options);
}

/// Add the step that probes OpenSSL again and compares it with this build.
///
/// Note:
/// - The step always runs and never changes the build. A difference fails it.
///
/// Param:
/// b - *std.Build (the build graph)
/// name - []const u8 (the step name, for example "openssl-check")
/// description - []const u8 (the step help text)
/// source - std.Build.LazyPath (the path of `scripts/openssl_check.zig`)
/// openssl - ?OpensslProbe (the result of `detectOpenssl`)
///
/// Return:
/// - void
pub fn addOpensslCheck(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    source: std.Build.LazyPath,
    openssl: ?OpensslProbe,
) void {
    const check_exe = b.addExecutable(.{
        .name = "tlz-openssl-check",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .root_source_file = source,
        }),
    });

    const check_run = b.addRunArtifact(check_exe);
    check_run.addArg(configuredState(b, openssl));
    check_run.has_side_effects = true;

    const check_step = b.step(name, description);
    check_step.dependOn(&check_run.step);
}

/// Add the unit and edge tests of the build helpers under `build/` to `step`.
///
/// Param:
/// b - *std.Build (the build graph)
/// step - *std.Build.Step (the unit and edge step)
/// sources - []const std.Build.LazyPath (the files under `scripts/`)
///
/// Return:
/// - void
pub fn addBuildHelperTests(
    b: *std.Build,
    step: *std.Build.Step,
    sources: []const std.Build.LazyPath,
) void {
    for (sources) |source| {
        const helper_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .target = b.graph.host,
                .root_source_file = source,
            }),
        });
        const helper_run = b.addRunArtifact(helper_tests);

        step.dependOn(&helper_run.step);
    }
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
    tlz_options.addOption(bool, "openssl", openssl != null);

    const tlz = b.addModule("tlz", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/lib.zig"),
    });
    tlz.addOptions("tlz_options", tlz_options);
    if (openssl) |found| linkOpenssl(b, target, optimize, tlz, &found);

    // Unit and edge: the in-file tests under src/, collected through src/test.zig
    const unit_edge_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/test.zig"),
    });
    unit_edge_mod.addOptions("tlz_options", tlz_options);
    if (openssl) |found| linkOpenssl(b, target, optimize, unit_edge_mod, &found);

    const unit_edge_tests = b.addTest(.{
        .root_module = unit_edge_mod,
    });
    const unit_edge_run = b.addRunArtifact(unit_edge_tests);

    const unit_edge_step = b.step("unit_edge-test", "TLZ: Run unit & edge tests.");
    unit_edge_step.dependOn(&unit_edge_run.step);
    addBuildHelperTests(b, unit_edge_step, &.{
        b.path("scripts/OpensslProbe.zig"),
        b.path("scripts/openssl_check.zig"),
    });

    // Behaviour: one test binary per suite file
    const behaviour_step = b.step("behaviour-test", "TLZ: Run behaviour tests.");
    addSuites(b, target, optimize, tlz, behaviour_step, &BEHAVIOUR_SUITES);

    const all_step = b.step("all-test", "TLZ: Run unit, edge, and behaviour tests.");
    all_step.dependOn(unit_edge_step);
    all_step.dependOn(behaviour_step);

    // OpenSSL check: probe again, compare with this build
    addOpensslCheck(
        b,
        "openssl-check",
        "TLZ: Probe OpenSSL again and compare it with this build.",
        b.path("scripts/openssl_check.zig"),
        openssl,
    );

    // Examples
    addExamples(b, target, optimize, tlz);
}

