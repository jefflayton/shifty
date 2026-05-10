const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_options: std.Build.ExecutableOptions = .{
        .name = "z-shift",
        .root_module = mod,
    };

    const exe = b.addExecutable(exe_options);
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run executable");
    run_step.dependOn(&run_exe.step);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    // ZLS Check
    const check_exe = b.addExecutable(exe_options);
    const check_step = b.step("check", "Compilation check");
    check_step.dependOn(&check_exe.step);

    // Tests
    const test_step = b.step("test", "run unit tests");
    const mod_test = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&mod_test.step);
}
