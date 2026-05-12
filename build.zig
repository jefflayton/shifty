const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const menubar = b.addTranslateC(.{
        .root_source_file = b.path("src/menubar.h"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("menubar", menubar.createModule());
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFile(.{
        .file = b.path("src/menubar.m"),
        .flags = &.{ "-fobjc-arc", "-fmodules" },
    });
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("Foundation", .{});

    const exe_options: Build.ExecutableOptions = .{
        .name = "shifty",
        .root_module = mod,
    };

    const exe = b.addExecutable(exe_options);
    b.installArtifact(exe);
    buildMacOS(b, exe);

    // Run Step
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

fn buildMacOS(b: *Build, exe: *Build.Step.Compile) void {
    // Move executable to Shifty.app
    const copy_bin = b.addSystemCommand(&.{
        "cp",
    });
    copy_bin.addArtifactArg(exe);
    copy_bin.addArg("platforms/macos/Shifty.app/Contents/MacOS/shifty");
    b.getInstallStep().dependOn(&copy_bin.step);

    // Sign MacOS App
    const sign = b.addSystemCommand(&.{
        "codesign", "--force", "--deep", "--sign", "-", "Shifty.app",
    });
    sign.step.dependOn(&copy_bin.step);
}
