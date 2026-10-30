const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        // core.local reads the timezone via libc
        .link_libc = true,
    });

    const unit_tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // The shared database. Separate from core so the shift math stays free
    // of SQLite for anything that only needs a clock-out time.
    const sqlite = b.dependency("sqlite", .{});
    const sqlite_h = b.addTranslateC(.{
        .root_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    const store = b.createModule(.{
        .root_source_file = b.path("src/store/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    store.addImport("core", core);
    store.addImport("c", sqlite_h.createModule());
    store.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            "-std=c99",
            // Each connection is used from one thread at a time.
            "-DSQLITE_THREADSAFE=2",
            // "name" is an identifier, never a string literal.
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",
        },
    });

    const store_tests = b.addTest(.{ .root_module = store });
    test_step.dependOn(&b.addRunArtifact(store_tests).step);

    const integrations = b.createModule(.{
        .root_source_file = b.path("src/integrations/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integrations_tests = b.addTest(.{ .root_module = integrations });
    test_step.dependOn(&b.addRunArtifact(integrations_tests).step);

    const macos_step = buildMacOS(b, optimize, core);
    b.getInstallStep().dependOn(macos_step);

    const tui = buildTui(b, target, optimize, core);
    test_step.dependOn(tui.tests);
    const tui_step = tui.step;
    const cli = buildCli(b, target, optimize, .{ .core = core, .store = store, .integrations = integrations });
    test_step.dependOn(cli.tests);

    const all = b.step("all", "Build all applicable apps");
    all.dependOn(test_step);
    all.dependOn(tui_step);
    all.dependOn(cli.step);
    if (target.result.os.tag == .macos) all.dependOn(macos_step);

    const check = b.step("check", "Compile-check all");
    check.dependOn(tui_step);
    check.dependOn(cli.step);
    check.dependOn(macos_step);
}

fn buildCli(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: struct { core: *Build.Module, store: *Build.Module, integrations: *Build.Module },
) struct { step: *Build.Step, tests: *Build.Step } {
    const cli_step = b.step("cli", "Build the CLI");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", deps.core);
    mod.addImport("store", deps.store);
    mod.addImport("integrations", deps.integrations);

    const exe = b.addExecutable(.{
        .name = "shifty",
        .root_module = mod,
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    cli_step.dependOn(&install_exe.step);

    const run_step = b.step("run-cli", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install_exe.step);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    return .{ .step = cli_step, .tests = &run_tests.step };
}

fn buildTui(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *Build.Module,
) struct { step: *Build.Step, tests: *Build.Step } {
    const tui_step = b.step("tui", "Build the TUI");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/tui/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", core);

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("vaxis", vaxis.module("vaxis"));

    const exe_opts: Build.ExecutableOptions = .{
        .name = "shifty-tui",
        .root_module = mod,
    };
    const exe = b.addExecutable(exe_opts);
    const install_exe = b.addInstallArtifact(exe, .{});
    tui_step.dependOn(&install_exe.step);

    const run_step = b.step("run-tui", "Run the TUI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install_exe.step);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    return .{ .step = tui_step, .tests = &run_tests.step };
}

fn buildMacOS(
    b: *Build,
    optimize: std.builtin.OptimizeMode,
    core: *Build.Module,
) *Build.Step {
    const macos_step = b.step("macos", "Build the macOS app");

    const target = b.resolveTargetQuery(.{
        .os_tag = .macos,
        .cpu_arch = .aarch64,
        .os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } },
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/macos.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", core);

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
    const sparkle_dep = b.dependency("sparkle", .{
        .target = target,
        .optimize = optimize,
    });

    const clean_sparkle = b.addSystemCommand(&.{
        "rm",
        "-rf",
        bundle_path ++ "/Frameworks/Sparkle.framework",
    });

    const cp_sparkle = b.addSystemCommand(&.{ "cp", "-R" });
    cp_sparkle.addDirectoryArg(sparkle_dep.path("Sparkle.framework"));
    cp_sparkle.addArg(
        bundle_path ++ "/Frameworks/Sparkle.framework",
    );
    cp_sparkle.step.dependOn(&clean_sparkle.step);
    // The copy lands in Contents/Frameworks, which inst_app creates.
    cp_sparkle.step.dependOn(&inst_app.step);

    // Sparkle's CLI tools (generate_appcast, sign_update, ...) for release CI
    const tools_step = b.step("sparkle-tools", "Install Sparkle CLI tools to zig-out/sparkle/bin");
    const mk_tools = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/sparkle" });
    const cp_tools = b.addSystemCommand(&.{ "cp", "-R" });
    cp_tools.addDirectoryArg(sparkle_dep.path("bin"));
    cp_tools.addArg("zig-out/sparkle/");
    cp_tools.step.dependOn(&mk_tools.step);
    tools_step.dependOn(&cp_tools.step);

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

    const io = b.graph.io;
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

    const bundle_step = bundle(b, app, &codesign.step);
    const bundle_opt = b.option(bool, "bundle", "bundle after build") orelse false;
    macos_step.dependOn(if (bundle_opt) bundle_step else &codesign.step);

    // Tests for the app's model layer, linked against the Zig core through
    // the same C ABI the app uses.
    const test_macos = b.step("test-macos", "Run macOS model tests");
    const ffi_obj = b.addObject(.{
        .name = "shifty-ffi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const swift_tests = b.addSystemCommand(&.{
        "swiftc",
        "-target",
        "arm64-apple-macos15.0",
        "-import-objc-header",
    });
    swift_tests.addFileArg(b.path("src/core/shifty.h"));
    var models = std.Io.Dir.cwd().openDir(io, macos ++ "/Models", .{ .iterate = true }) catch @panic("Missing Models dir");
    defer models.close(io);
    var models_it = models.iterate();
    while (models_it.next(io) catch @panic("iterate fail")) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".swift")) {
            swift_tests.addFileArg(b.path(b.fmt(macos ++ "/Models/{s}", .{entry.name})));
        }
    }
    swift_tests.addFileArg(b.path("tests/macos/main.swift"));
    swift_tests.addFileArg(ffi_obj.getEmittedBin());
    swift_tests.addArg("-o");
    const test_bin = swift_tests.addOutputFileArg("shifty-macos-tests");
    const run_swift_tests = std.Build.Step.Run.create(b, "run shifty-macos-tests");
    run_swift_tests.addFileArg(test_bin);
    test_macos.dependOn(&run_swift_tests.step);

    const run_cmd = b.addSystemCommand(&.{bin_str});
    const run_step = b.step("run-macos", "Run macOS executable");
    run_cmd.step.dependOn(&link.step);
    run_step.dependOn(&run_cmd.step);

    return macos_step;
}

/// `signed` must finish before staging starts. Depending on it from the
/// returned step alone isn't enough: the copy would race the build and
/// can package a half-built, unsigned app.
fn bundle(b: *Build, app_path: []const u8, signed: *Build.Step) *Build.Step {
    const bundle_step = b.step("bundle", "Bundle macOS DMG");

    const dmg_stage = "zig-out/dmg";

    const clean_stage = b.addSystemCommand(&.{ "rm", "-rf", dmg_stage });
    clean_stage.step.dependOn(signed);

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
