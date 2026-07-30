const std = @import("std");
const page = @import("slotted_page.zig");

pub fn BTree(comptime fanout: usize, comptime k: type, comptime v: type) type {
    return struct {
        root: *Page,
    
        const Self = @This();
        const Page = page.SlottedPage(fanout, k, v);

        pub fn init(gpa: std.mem.Allocator) !Self {
            const root = try gpa.create(Page);
            errdefer gpa.destroy(root);

            root.* = .empty;
            return .{.root = root};
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, key: k, value: v) !void {
            self.root = try self.root.insert(gpa, key, value);
        }

        pub fn get(self: *const Self, key: k) ?v {
            return self.root.get(key);
        }
    };
}

test "bleh" {
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const gpa = allocator.allocator();

    const Tree = BTree(2, i32, i32);

    var tree: Tree = try .init(gpa);
    try tree.insert(gpa, 0, 0);
    try tree.insert(gpa, 1, 1);
    try tree.insert(gpa, 2, 2);

    // OK a split should have occured
    const left = tree.root.cells[0];
    const right = tree.root.cells[1];

    try std.testing.expectEqual(left.key, 0);
    try std.testing.expectEqual(right.key, 1);

    // try tree.insert(gpa, 3, 3);
}
