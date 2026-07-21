const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.resolveTargetQuery(.{
        .os_tag = .macos,
        .cpu_arch = .aarch64,
        .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
    });
    const optimize = b.standardOptimizeOption(.{});

    const build_macos_step = buildMacOS(b, target, optimize);
    b.getInstallStep().dependOn(build_macos_step);

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = core_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

fn installSparkle(b: *Build) *Build.Step.Run {
    const SPARKLE_VERSION = "2.9.2";

    const fetch_sparkle = b.addSystemCommand(&.{
        "sh", "-c",
        "test -d .cache/sparkle/Sparkle.framework || " ++
            "( mkdir -p .cache/sparkle && " ++
            "curl -L https://github.com/sparkle-project/Sparkle/releases/download/" ++ SPARKLE_VERSION ++ "/Sparkle-" ++ SPARKLE_VERSION ++ ".tar.xz" ++
            " -o .cache/sparkle/sparkle.tar.xz && " ++
            "tar -xf .cache/sparkle/sparkle.tar.xz -C .cache/sparkle Sparkle.framework bin )",
    });

    return fetch_sparkle;
}

fn buildMacOS(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Step {
    const io = b.graph.io;

    const build_macos_step = b.step("build-macos", "Build the app for MacOS");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app = "zig-out/Shifty.app";
    const bundle_path = app ++ "/Contents";
    const bin_str = bundle_path ++ "/MacOS/shifty";
    const bin = b.path(bin_str);
    const frameworks = b.path(bundle_path ++ "/Frameworks");
    const macos = "platforms/macos";

    const inst_app = b.addSystemCommand(&.{
        "mkdir",                     "-p",
        bundle_path ++ "/MacOS",     bundle_path ++ "/Frameworks",
        bundle_path ++ "/Resources",
    });

    // Install plist
    const inst_info_plist = b.addInstallFile(
        b.path(macos ++ "/Info.plist"),
        "Shifty.app/Contents/Info.plist",
    );

    const inst_alarm = b.addInstallFile(b.path(macos ++ "/Resources/alarm.caf"), "Shifty.app/Contents/Resources/alarm.caf");

    // Install Sparkle
    const inst_sparkle = installSparkle(b);
    inst_sparkle.step.dependOn(&inst_app.step);

    const clean_sparkle = b.addSystemCommand(&.{
        "rm", "-rf", bundle_path ++ "/Frameworks/Sparkle.framework",
    });
    clean_sparkle.step.dependOn(&inst_sparkle.step);
    const cp_sparkle = b.addSystemCommand(&.{
        "cp",                               "-R",
        ".cache/sparkle/Sparkle.framework", bundle_path ++ "/Frameworks/Sparkle.framework",
    });
    cp_sparkle.step.dependOn(&clean_sparkle.step); // was: inst_sparkle

    const obj_options: Build.ObjectOptions = .{
        .name = "shifty",
        .root_module = mod,
    };
    const zig_obj = b.addObject(obj_options);

    const menubar_obj_path = b.path(".zig-cache/menubar.o");
    const swift_obj = b.addSystemCommand(&.{
        "swiftc",
        "-target",
        "arm64-apple-macos15.0",
        "-Xlinker",
        "-rpath",
        "-Xlinker",
        "@executable_path/../Frameworks",
        "-F",
    });
    swift_obj.addFileArg(frameworks);
    swift_obj.addArgs(&.{
        "-framework",
        "Sparkle",
        "-import-objc-header",
        "src/core/shifty.h",
        "-parse-as-library",
        "-wmo",
        "-emit-object",
    });

    var dir = std.Io.Dir.cwd().openDir(io, "platforms/macos", .{ .iterate = true }) catch @panic("Missing platforms/macos dir");
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("walk alloc fail");
    defer walker.deinit();
    while (walker.next(io) catch @panic("walk fail")) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".swift")) {
            const p = b.fmt("platforms/macos/{s}", .{entry.path});
            swift_obj.addFileArg(b.path(p));
        }
    }

    swift_obj.addArg("-o");
    swift_obj.addFileArg(menubar_obj_path);
    swift_obj.step.dependOn(&cp_sparkle.step);

    const link = b.addSystemCommand(&.{
        "swiftc",
        "-target",
        "arm64-apple-macos15.0",
        "-Xlinker",
        "-rpath",
        "-Xlinker",
        "@executable_path/../Frameworks",
        "-F",
    });
    link.addFileArg(frameworks);
    link.addArgs(&.{
        "-framework",
        "Sparkle",
        "-import-objc-header",
        "src/core/shifty.h",
    });
    link.addFileArg(menubar_obj_path);
    link.addFileArg(zig_obj.getEmittedBin());
    link.addArg("-o");
    link.addFileArg(bin);
    link.step.dependOn(&swift_obj.step);
    link.step.dependOn(&inst_app.step);
    link.step.dependOn(&inst_info_plist.step);
    link.step.dependOn(&inst_alarm.step);

    // Sign inside-out, WITHOUT --deep. --deep would re-sign (and clobber)
    // Sparkle.framework's own valid signature; Sparkle then refuses updates.
    // Sign the Mach-O binary first, then seal the outer .app on top of it.
    const codesign_bin = b.addSystemCommand(&.{
        "codesign", "--force", "--options=runtime",
        "--sign",         "-", // "-" = ad-hoc identity
        "--entitlements", macos ++ "/entitlements.plist",
    });
    codesign_bin.addFileArg(bin);
    codesign_bin.step.dependOn(&link.step);

    const codesign = b.addSystemCommand(&.{
        "codesign", "--force", "--options=runtime",
        "--sign",         "-", // "-" = ad-hoc identity
        "--entitlements", macos ++ "/entitlements.plist",
        app,
    });
    codesign.step.dependOn(&codesign_bin.step);

    const bundle_step = bundle(b, app);
    const bundle_opt = b.option(bool, "bundle", "bundle after build") orelse false;
    if (bundle_opt) {
        bundle_step.dependOn(&codesign.step);
        build_macos_step.dependOn(bundle_step);
    } else {
        build_macos_step.dependOn(&codesign.step);
    }

    const run_cmd = b.addSystemCommand(&.{bin_str});
    const run_step = b.step("run", "Run executable");
    run_cmd.step.dependOn(&link.step);
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addObject(obj_options);
    const check_step = b.step("check", "Compilation check");
    check_step.dependOn(&check_exe.step);

    return build_macos_step;
}

fn bundle(b: *Build, app_path: []const u8) *Build.Step {
    const bundle_step = b.step("bundle", "Bundle macOS DMG");

    const dmg_stage = "zig-out/dmg";

    const clean_stage = b.addSystemCommand(&.{ "rm", "-rf", dmg_stage });

    const mk_stage = b.addSystemCommand(&.{ "mkdir", "-p", dmg_stage });
    mk_stage.step.dependOn(&clean_stage.step);

    const stage_app = b.addSystemCommand(&.{ "cp", "-R", app_path });
    stage_app.addArg(dmg_stage ++ "/Shifty.app");
    stage_app.step.dependOn(&mk_stage.step);

    const app_link = b.addSystemCommand(&.{
        "ln",
        "-sf",
        "/Applications",
        dmg_stage ++ "/Applications",
    });
    app_link.step.dependOn(&stage_app.step);

    const dmg = b.addSystemCommand(&.{
        "hdiutil",    "create",
        "-volname",   "Shifty",
        "-srcfolder", dmg_stage,
        "-ov", // overwrite if exists
        "-format",            "UDZO", // compressed
        "zig-out/Shifty.dmg",
    });
    dmg.step.dependOn(&app_link.step);

    bundle_step.dependOn(&dmg.step);

    return bundle_step;
}
