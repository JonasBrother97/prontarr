const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });
    const zqlite = b.dependency("zqlite", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const curl = b.addTranslateC(.{ .root_source_file = b.path("src/curl.h"), .target = target, .optimize = optimize });
    curl.linkSystemLibrary("curl", .{});
    mod.addImport("curl", curl.createModule());
    mod.linkSystemLibrary("curl", .{});
    mod.addImport("httpz", httpz.module("httpz"));
    mod.addImport("zqlite", zqlite.module("zqlite"));
    for ([_][]const u8{ "index.html", "app.js", "app.css" }) |file| {
        mod.addAnonymousImport(file, .{ .root_source_file = b.path(b.fmt("frontend/dist/{s}", .{file})) });
    }
    const exe = b.addExecutable(.{ .name = "prontarr", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the local API and dashboard").dependOn(&run.step);
    const testmod = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    testmod.addImport("curl", curl.createModule());
    testmod.linkSystemLibrary("curl", .{});
    const tests = b.addTest(.{ .root_module = testmod });
    b.step("test", "Test decision engine and adapter safety").dependOn(&b.addRunArtifact(tests).step);
}
