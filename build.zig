const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const known_folders_module = b.dependency("known_folders", .{}).module("known-folders");
    const zigwin32_module = b.dependency("zigwin32", .{}).module("zigwin32");

    const resource = b.addTranslateC(.{
        .root_source_file = b.path("res/resource.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "multimouse",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .win32_manifest = b.path("src/main.manifest"),
    });

    exe.mingw_unicode_entry_point = true;
    exe.subsystem = .Windows;
    exe.root_module.addImport("known-folders", known_folders_module);
    exe.root_module.addImport("win32", zigwin32_module);
    exe.root_module.addImport("resource", resource.createModule());
    exe.addWin32ResourceFile(.{ .file = b.path("res/resource.rc") });
    exe.addIncludePath(b.path("res"));

    b.installArtifact(exe);
}
