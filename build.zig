const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    _ = b.step("test", "Run tests");

    const target = b.resolveTargetQuery(.{
        .os_tag = .macos,
        .cpu_arch = .aarch64,
    });
    const optimize = b.standardOptimizeOption(.{});

    const app = "zig-out/Shifty.app";
    const bundle = app ++ "/Contents";
    const bin_str = bundle ++ "/MacOS/shifty";
    const bin = b.path(bin_str);
    const frameworks = b.path(bundle ++ "/Frameworks");
    const macos = "platforms/macos";

    const inst_app = b.addSystemCommand(&.{
        "mkdir", "-p", bundle ++ "/MacOS", bundle ++ "/Frameworks",
    });

    // Install plist
    const inst_info_plist = b.addInstallFile(
        b.path(macos ++ "/Info.plist"),
        "Shifty.app/Contents/Info.plist",
    );

    // Install Sparkle
    const inst_sparkle = installSparkle(b);
    inst_sparkle.step.dependOn(&inst_app.step);

    const cp_sparkle = b.addSystemCommand(&.{
        "cp",                               "-R",
        ".cache/sparkle/Sparkle.framework", bundle ++ "/Frameworks/Sparkle.framework",
    });
    cp_sparkle.step.dependOn(&inst_sparkle.step);

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

    const menubar_obj_path = b.path(".zig-cache/menubar.o");
    const swift_obj = b.addSystemCommand(&.{
        "swiftc",
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
        "-parse-as-library",
        "-emit-object",
    });
    swift_obj.addFileArg(b.path("src/menubar.swift"));
    swift_obj.addArg("-o");
    swift_obj.addFileArg(menubar_obj_path);
    swift_obj.step.dependOn(&cp_sparkle.step);

    const link = b.addSystemCommand(&.{
        "swiftc",
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
    });
    link.addFileArg(menubar_obj_path);
    link.addFileArg(zig_obj.getEmittedBin());
    link.addArg("-o");
    link.addFileArg(bin);
    link.step.dependOn(&swift_obj.step);
    link.step.dependOn(&inst_app.step);
    link.step.dependOn(&inst_info_plist.step);

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

    const dmg_stage = "zig-out/dmg";

    const clean_stage = b.addSystemCommand(&.{ "rm", "-rf", dmg_stage });
    clean_stage.step.dependOn(&codesign.step);

    const mk_stage = b.addSystemCommand(&.{ "mkdir", "-p", dmg_stage });
    mk_stage.step.dependOn(&clean_stage.step);

    const stage_app = b.addSystemCommand(&.{ "cp", "-R", app });
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

    b.getInstallStep().dependOn(&dmg.step);

    const run_cmd = b.addSystemCommand(&.{bin_str});
    const run_step = b.step("run", "Run executable");
    run_cmd.step.dependOn(&link.step);
    run_step.dependOn(&run_cmd.step);

    const check_exe = b.addObject(obj_options);
    const check_step = b.step("check", "Compilation check");
    check_step.dependOn(&check_exe.step);
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
