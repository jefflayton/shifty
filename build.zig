const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const dmg_path = b.path("Shifty.dmg");
    const macos_path = b.path("platforms/macos");
    const bundle_path = macos_path.join(b.allocator, "Shifty.app") catch @panic("Out of Memory");
    const bin_path = bundle_path.join(b.allocator, "Contents/MacOS/shifty") catch @panic("Out of Memory");
    const menubar_path = b.path("src/menubar.swift");
    const menubar_obj_path = b.path("zig-out/menubar.o");

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
        "-framework", "SwiftUI", // Required Frameworks
        "-framework", "AppKit",
        "-framework", "Foundation",
    });
    link.addFileArg(menubar_obj_path);
    link.addFileArg(zig_obj.getEmittedBin());
    link.addArg("-o");
    link.addFileArg(bin_path);
    link.step.dependOn(&swift_obj.step);
    link.step.dependOn(&zig_obj.step);

    const app_symlink = b.addSystemCommand(&.{
        "ln",
        "-sf",
        "/Applications",
    });
    app_symlink.addFileArg(macos_path.join(b.allocator, "Applications") catch @panic("Out of Memory"));
    app_symlink.step.dependOn(&link.step);

    const dmg = b.addSystemCommand(&.{
        "hdiutil",    "create",
        "-volname",   "Shifty",
        "-srcfolder",
    });
    dmg.addFileArg(macos_path);
    dmg.addArgs(&.{
        "-ov", // overwrite if exists
        "-format", "UDZO", // compressed
    });
    dmg.addFileArg(dmg_path);
    dmg.step.dependOn(&app_symlink.step);

    b.getInstallStep().dependOn(&dmg.step);

    const run_cmd = b.addSystemCommand(&.{bin_path.src_path.sub_path});
    const run_step = b.step("run", "Run executable");
    run_cmd.step.dependOn(&link.step);
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addObject(obj_options);
    const check_step = b.step("check", "Compilation check");
    check_step.dependOn(&check_exe.step);
}
