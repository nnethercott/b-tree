const std = @import("std");
const expect = std.testing.expect;

const btree = @import("tree.zig");
const page = @import("slotted_page.zig");
const manager = @import("page_manager.zig");
const r = @import("roaring.zig");

const BTree = btree.BTree;

pub fn main(init: std.process.Init) !void {
    _ = init;
    const bitset: manager.PageManager = .init();
    r.roaring_bitmap_add(bitset.in_use, 1);
    try expect(r.roaring_bitmap_contains(bitset.in_use, 1));
}

fn bleh(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    const Tree = BTree(2, i32, i32);

    var tree: Tree = try .init(gpa);
    std.debug.print("{any}\n", .{@alignOf(page.SlottedPage(2, i32, i32))});

    try tree.insert(gpa, 0, 0);
    // std.debug.print("{any}\n", .{tree.root});
    try tree.insert(gpa, 1, 1);
    // std.debug.print("{any}\n", .{tree.root});
    try tree.insert(gpa, 2, 2);
    // std.debug.print("{any}\n", .{tree.root.cells[0]});
    // std.debug.print("{any}\n", .{tree.root.header.right_page});
    try tree.insert(gpa, 3, 3);
    try tree.insert(gpa, 4, 4);

    // std.debug.print("get {any}\n", .{tree.get(2)});
    // std.debug.print("get {any}\n", .{tree.root.cells[0]});
    // std.debug.print("get {any}\n", .{tree.root.header.right_page});

}
