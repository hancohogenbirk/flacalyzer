const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "flacalyzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    exe.linkSystemLibrary("FLAC");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run flacalyzer");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const test_step = b.step("test", "Run unit tests");

    // Test analysis module (core algorithms)
    const analysis_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/analysis.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    analysis_tests.linkLibC();
    analysis_tests.linkSystemLibrary("FLAC");

    const run_analysis_tests = b.addRunArtifact(analysis_tests);
    test_step.dependOn(&run_analysis_tests.step);

    // Test utils module
    const utils_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    utils_tests.linkLibC();
    utils_tests.linkSystemLibrary("FLAC");

    const run_utils_tests = b.addRunArtifact(utils_tests);
    test_step.dependOn(&run_utils_tests.step);

    // Print success message after all tests pass
    const test_success = b.addSystemCommand(&[_][]const u8{
        "echo",
        "\n✅ All tests passed successfully!\n",
    });
    test_success.step.dependOn(&run_analysis_tests.step);
    test_success.step.dependOn(&run_utils_tests.step);
    test_step.dependOn(&test_success.step);
}
