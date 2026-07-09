//! This build belongs to your app, written once by `native eject`:
//! the `native` CLI stops generating a build graph and
//! drives this file through `zig build` instead, and it will
//! never rewrite it. `addApp` wires the complete standard app
//! build — executable, `zig build run`, `zig build test`, and
//! the -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags —
//! from the framework's build/app.zig, so a framework upgrade
//! still upgrades your build. Extend from here with
//! `addAppArtifacts` when you need extra sources or steps.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "inpute" });

    // Global input capture (§6 of the functional spec) needs raw access to
    // ApplicationServices (CGEventTap, AXIsProcessTrusted) and IOKit/HID
    // (IOHIDCheckAccess) beyond what the standard app build links.
    const os_tag = artifacts.exe.root_module.resolved_target.?.result.os.tag;
    const compiles = [_]*std.Build.Step.Compile{ artifacts.exe, artifacts.tests };

    switch (os_tag) {
        .macos => for (compiles) |compile| {
            compile.root_module.linkFramework("ApplicationServices", .{});
            compile.root_module.linkFramework("IOKit", .{});
            compile.root_module.linkFramework("CoreFoundation", .{});
            // The standard app build only adds the SDK frameworks search
            // path to the main exe module (build/app.zig); the `tests`
            // module needs it too now that it links frameworks of its own.
            if (b.sysroot) |sysroot| {
                compile.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            }
        },
        .windows => for (compiles) |compile| {
            // `user32`/`kernel32` are already linked by the standard app
            // build; `advapi32` (Registry) is ours for autostart (§10).
            compile.root_module.linkSystemLibrary("advapi32", .{});
        },
        .linux => for (compiles) |compile| {
            // XRecord (§6, §7.3) needs libX11 (the core Xlib entry
            // points) and libXtst (the RECORD extension's client lib).
            compile.root_module.linkSystemLibrary("X11", .{});
            compile.root_module.linkSystemLibrary("Xtst", .{});
        },
        else => {},
    }
}
