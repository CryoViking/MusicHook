const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "music",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_artifact = b.addRunArtifact(exe);
    run_artifact.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_artifact.addArgs(args);
    }

    const run_step = b.step("run", "Run MusicHook");
    run_step.dependOn(&run_artifact.step);
}
