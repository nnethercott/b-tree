const std = @import("std");
const page = @import("slotted_page.zig");
const Store = @import("Store.zig");

pub fn BTree(comptime fanout: usize, comptime k: type, comptime v: type) type {
    return struct {
        root: *Page,
        store: *Store,

        const Self = @This();
        pub const Page = page.SlottedPage(fanout, k, v);

        pub fn init(store: *Store) !Self {
            const entry = try store.alloc();
            const root: *Page = @ptrCast(@alignCast(entry.bytes));
            root.* = .{
                .header = .{
                    .id = entry.key,
                    .kind = .Leaf,
                },
            };
            return .{ .root = root, .store = store };
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, key: k, value: v) !void {
            self.root = try self.root.insert(gpa, self.store, key, value);
        }

        pub fn get(self: *const Self, key: k) ?v {
            return self.root.get(self.store, key);
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
    // const left = tree.root.cells[0];
    // const right = tree.root.cells[1];

    // try std.testing.expectEqual(left.key, 0);
    // try std.testing.expectEqual(right.key, 1);

    return error.SkipZigTest;
}
