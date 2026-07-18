const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const library_module = b.createModule(.{
        .root_source_file = b.path("src/library_module/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils_module = b.createModule(.{
        .root_source_file = b.path("src/utils_module/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bridge_module = b.createModule(.{
        .root_source_file = b.path("src/bridge_module/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const music = b.addExecutable(.{
        .name = "music",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    music.root_module.addImport("library_module", library_module);
    music.root_module.addImport("utils_module", utils_module);
    music.root_module.addImport("bridge_module", bridge_module);

    const native_host = b.addExecutable(.{
        .name = "music-hook-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    native_host.root_module.addImport("utils_module", utils_module);
    native_host.root_module.addImport("bridge_module", bridge_module);

    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    host_tests.root_module.addImport("utils_module", utils_module);
    host_tests.root_module.addImport("bridge_module", bridge_module);

    const run_host_tests = b.addRunArtifact(host_tests);
    const test_host_step = b.step(
        "test-host",
        "Run native host tests",
    );
    test_host_step.dependOn(&run_host_tests.step);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    cli_tests.root_module.addImport("library_module", library_module);
    cli_tests.root_module.addImport("utils_module", utils_module);
    cli_tests.root_module.addImport("bridge_module", bridge_module);

    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_cli_step = b.step(
        "test-cli",
        "Run CLI tests",
    );
    test_cli_step.dependOn(&run_cli_tests.step);

    b.installArtifact(music);
    b.installArtifact(native_host);

    const run_music = b.addRunArtifact(music);
    run_music.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_music.addArgs(args);
    }

    const run_step = b.step("run", "Run MusicHook");
    run_step.dependOn(&run_music.step);
}
