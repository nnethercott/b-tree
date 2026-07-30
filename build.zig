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
        }),
    });

    b.installArtifact(b_tree_exe);

    const run = b.addRunArtifact(b_tree_exe);
    const step = b.step("run", "runs main.zig");
    step.dependOn(&run.step);

    // tests
    const test_step = b.step("test", "runs the unit tests");
    const test_files = [_][]const u8 { "src/tree.zig", "src/slotted_page.zig" };

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
