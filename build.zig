const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_pubky = b.option(bool, "pubky", "Enable Pubky discovery (requires cargo)") orelse true;

    // ----------------------------------------------------------------
    // libsecp256k1 — vendored via build.zig.zon, built as a static C lib.
    // We only need the schnorrsig + extrakeys modules for Nostr (NIP-01).
    // ----------------------------------------------------------------
    const secp_dep = b.dependency("secp256k1", .{});
    const secp_root = secp_dep.path("");

    const secp = b.addLibrary(.{
        .name = "secp256k1",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    secp.root_module.addCSourceFiles(.{
        .root = secp_root,
        .files = &.{
            "src/secp256k1.c",
            "src/precomputed_ecmult.c",
            "src/precomputed_ecmult_gen.c",
        },
        .flags = &.{
            "-std=c89",
            "-Wno-unused-function",
            "-Wno-nonnull-compare",
            "-Wno-long-long",
        },
    });
    secp.root_module.addIncludePath(secp_dep.path("."));
    secp.root_module.addIncludePath(secp_dep.path("src"));
    secp.root_module.addIncludePath(secp_dep.path("include"));
    // Required compile-time flags. See secp256k1's CMakeLists.txt.
    const secp_macros: []const [2][]const u8 = &.{
        .{ "ENABLE_MODULE_SCHNORRSIG", "1" },
        .{ "ENABLE_MODULE_EXTRAKEYS", "1" },
        .{ "ECMULT_WINDOW_SIZE", "15" },
        // The (COMB_BLOCKS, COMB_TEETH) = (11, 6) pair is libsecp256k1's
        // encoding for what its CMake exposes as ECMULT_GEN_KB=22 — a ~22 KiB
        // precomputed signing table (vs 86 KiB default). We don't need
        // fastest-possible signing.
        .{ "COMB_BLOCKS", "11" },
        .{ "COMB_TEETH", "6" },
    };
    for (secp_macros) |kv| {
        secp.root_module.addCMacro(kv[0], kv[1]);
    }
    // Expose libsecp256k1 public headers to anything that links us.
    secp.installHeadersDirectory(secp_dep.path("include"), "", .{});

    // ----------------------------------------------------------------
    // carl library module
    // ----------------------------------------------------------------
    const lib_mod = b.addModule("carl", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .link_libc = true,
    });
    lib_mod.linkLibrary(secp);
    lib_mod.addIncludePath(secp_dep.path("include"));

    var pubky_cargo_step: ?*std.Build.Step = null;
    if (enable_pubky) {
        pubky_cargo_step = addPubkyBridge(b, lib_mod, target);
    }

    // ----------------------------------------------------------------
    // CLI executable
    // ----------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "carl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "carl", .module = lib_mod },
            },
        }),
    });
    exe.linkLibrary(secp);
    exe.root_module.addIncludePath(secp_dep.path("include"));
    if (enable_pubky) {
        linkPubkyBridge(b, exe.root_module, target);
        if (pubky_cargo_step) |cargo| exe.step.dependOn(cargo);
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run carl");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ----------------------------------------------------------------
    // Tests
    // ----------------------------------------------------------------
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    if (enable_pubky) {
        linkPubkyBridge(b, lib_tests.root_module, target);
        if (pubky_cargo_step) |cargo| lib_tests.step.dependOn(cargo);
    }
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    if (enable_pubky) {
        if (pubky_cargo_step) |cargo| exe_tests.step.dependOn(cargo);
    }
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn addPubkyBridge(b: *std.Build, lib_mod: *std.Build.Module, target: std.Build.ResolvedTarget) *std.Build.Step {
    const manifest = b.pathFromRoot("native/carl_pubky_bridge/Cargo.toml");
    const cargo = b.addSystemCommand(&.{
        "cargo", "build", "--release", "--manifest-path", manifest,
    });
    linkPubkyBridge(b, lib_mod, target);
    return &cargo.step;
}

fn linkPubkyBridge(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const lib_path = b.path("native/carl_pubky_bridge/target/release/libcarl_pubky_bridge.a");
    mod.addObjectFile(lib_path);
    mod.linkSystemLibrary("c++", .{});
    mod.linkSystemLibrary("pthread", .{});
    mod.linkSystemLibrary("m", .{});
    mod.linkSystemLibrary("dl", .{});
    if (target.result.os.tag == .macos) {
        mod.linkFramework("Security", .{});
        mod.linkFramework("SystemConfiguration", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
}
