const std = @import("std");

const test_targets = [_]std.Target.Query{
    .{}, // native
    // .{
    //     .cpu_arch = .x86_64,
    //     .os_tag = .linux,
    // }

};

pub fn build(b: *std.Build) void {
    const b_tree_exe = b.addExecutable(.{
        .name = "btree",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .optimize = b.standardOptimizeOption(.{}),
            .target = b.graph.host,
            // .link_libc = true,
        }),
    });

    // NOTE: can't use the build.zig.zon dep since its on zig 0.15.1
    // const droaring = b.dependency("roaring", .{});
    // b_tree_exe.root_module.addImport("roaring", droaring.module("roaring.zig"));
    // b_tree_exe.root_module.addCSourceFile(.{
    //     .file = b.path("roaring/roaring.c"),
    //     .flags = &.{},
    // });
    // b_tree_exe.root_module.addIncludePath(b.path("roaring"));

    b.installArtifact(b_tree_exe);

    const run = b.addRunArtifact(b_tree_exe);
    const step = b.step("run", "runs main.zig");
    step.dependOn(&run.step);

    // tests
    const test_step = b.step("test", "runs the unit tests");

    // imports are run twice ?
    const test_files = [_][]const u8{
        "src/tree.zig",
        "src/Store.zig",
    };

    for (test_files) |file| {
        for (test_targets) |target| {
            const unit_tests = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = b.resolveTargetQuery(target),
            }) });

            const run_test = b.addRunArtifact(unit_tests);
            test_step.dependOn(&run_test.step);
        }
    }
}
