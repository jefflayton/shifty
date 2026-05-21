// const builtin = @import("builtin");
const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.resolveTargetQuery(.{
        .os_tag = .macos,
        .cpu_arch = .aarch64,
    });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const obj_options: Build.ObjectOptions = .{
        .name = "shifty",
        .root_module = mod,
    };
    const zig_obj = b.addObject(obj_options);

    const menubar_path = b.path("src/menubar.swift");
    const menubar_obj_path = b.path("zig-out/menubar.o");

    const swift_obj = b.addSystemCommand(&.{
        "swiftc",
        "-parse-as-library",
        "-emit-object",
    });
    swift_obj.addFileArg(menubar_path);
    swift_obj.addArg("-o");
    swift_obj.addFileArg(menubar_obj_path);

    const link = b.addSystemCommand(&.{
        "swiftc",
        "-framework",
        "SwiftUI",
        "-framework",
        "AppKit",
        "-framework",
        "Foundation",
    });
    link.addFileArg(menubar_obj_path);
    link.addFileArg(zig_obj.getEmittedBin());
    link.addArgs(&.{ "-o", "zig-out/bin/shifty" });
    link.step.dependOn(&swift_obj.step);
    link.step.dependOn(&zig_obj.step);

    b.getInstallStep().dependOn(&link.step);

    const run_cmd = b.addSystemCommand(&.{"zig-out/bin/shifty"});
    const run_step = b.step("run", "Run executable");
    run_cmd.step.dependOn(&link.step);
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addObject(obj_options);
    const check_step = b.step("check", "Compilation check");
    check_step.dependOn(&check_exe.step);
}
