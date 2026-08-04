const std = @import("std");
const expect = std.testing.expect;

const btree = @import("tree.zig");
const page = @import("slotted_page.zig");
const manager = @import("page_manager.zig");
const r = @import("roaring.zig");

const BTree = btree.BTree;

pub fn main(init: std.process.Init) !void {
    try bleh(init);
}

fn foo(init: std.process.Init) !void {
    var m: manager.PageManager = try .init("nate.db", init.io, std.heap.pageSize());

    const buf = try m.nextPage();
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    _ = try std.fmt.allocPrint(fba.allocator(), "hello, from nate", .{});
    try m.map.write(init.io);

    _ = try m.nextPage();
    _ = try m.nextPage();
}

fn bleh(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    const Tree = BTree(2, i32, i32);

    var tree: Tree = try .init(gpa);

    try tree.insert(gpa, 0, 0);
    try tree.insert(gpa, 1, 1);
    try tree.insert(gpa, 2, 2);
    try tree.insert(gpa, 3, 3);
    try tree.insert(gpa, 4, 4);

    // nice !
    // this makes zero copy kinda nice i guess
    const slice: []u8 = @ptrCast(tree.root);
    std.debug.print("{any}\n", .{slice});

    const node: *Tree.Page = @ptrCast(@alignCast(slice));
    std.debug.print("{any}\n", .{node.cells[0].next_page.?.header.right_page.?});
}
