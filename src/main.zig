const std = @import("std");
const expect = std.testing.expect;

const btree = @import("tree.zig");
const BTree = btree.BTree;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    const Tree = BTree(2, i32, i32);

    var tree: Tree = try .init(gpa);
    try tree.insert(gpa, 0, 0);
    try tree.insert(gpa, 1, 1);
    try tree.insert(gpa, 2, 2);
}
