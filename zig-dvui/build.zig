const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl2,
    });
    const exe = b.addExecutable(.{
        .name = "zig-dvui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl2") },
            },
        }),
    });
    // db.zig uses the system SQLite C API, so the build needs
    // the system SQLite development package (libsqlite3-dev on
    // Ubuntu, sqlite-devel on Fedora); see db.zig. In Zig
    // 0.17, system libraries link through the root module,
    // not the executable step, and this also links libc.
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(exe);

    // Unit tests: recipe data (db.zig) and search
    // (search.zig) only — no encoding, UI, network, or
    // end-to-end tests. Neither test module imports DVUI;
    // the db tests link the system SQLite library like the
    // app does.
    const search_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/search.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_search_tests = b.addRunArtifact(search_tests);

    const db_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/db.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    db_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_db_tests = b.addRunArtifact(db_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_search_tests.step);
    test_step.dependOn(&run_db_tests.step);
}
