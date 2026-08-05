const std = @import("std");
const expect = std.testing.expect;
const Store = @import("Store.zig");

pub fn SlottedPage(comptime capacity: usize, comptime k: type, comptime v: type) type {
    // FIXME: comptime fn() comptime_int returning fanout from k, v as a default value
    // FIXME: add signature like .init(gpa, &cmpKey) ?

    return struct {
        header: Header,
        offsets: [capacity]usize = undefined,
        cells: [capacity]Cell = undefined,
        len: usize = 0,

        const Self = @This();
        pub const empty: Self = .{ .header = .leaf };

        const MAGIC_OFFSET: comptime_int = capacity + 1;

        fn firstCell(self: *const Self) ?Cell {
            if (self.len == 0) {
                return null;
            }
            return self.cells[self.offsets[0]];
        }

        fn lastCell(self: *const Self) ?Cell {
            if (self.len == 0) {
                return null;
            }
            return self.cells[self.offsets[self.len - 1]];
        }

        fn rightPage(self: *const Self) ?*Self {
            return self.header.right_page;
        }

        fn full(self: *const Self) bool {
            switch (self.header.kind) {
                .Leaf => return self.len == capacity,
                .Internal => return (self.len == capacity and self.header.right_page != null),
            }
        }

        fn offsetsSlice(self: *const Self) []const usize {
            return self.offsets[0..self.len];
        }

        fn cellsSlice(self: *const Self) []const Cell {
            return self.cells[0..];
        }

        /// Appends a cell unordered. Caller must ensure sorting of `offsets` afterwards
        fn pushAssumeCapacity(self: *Self, cell: Cell) void {
            const idx = self.nextFreeIdx() orelse self.len;
            self.offsets[self.len] = idx;
            self.cells[idx] = cell;
            self.len += 1;
        }

        fn insertSiblings(self: *Self, idx: usize, left: *Self, right: *Self) void {
            const cell_idx = self.nextFreeIdx() orelse self.len;
            // NOTE: when you have a cell with just one header ptr this fails !
            // case capacity = 1
            const cell: Cell = .{
                .key = right.firstCell().?.key,
                .next_page = left,
            };

            if (idx == MAGIC_OFFSET) {
                self.header.right_page = right;

                self.offsets[self.len] = cell_idx;
                self.cells[cell_idx] = cell;
                self.len += 1;

                return;
            }

            // shift offsets to the right by 1 at idx to make room for new cell
            @memcpy(self.offsets[idx + 1 .. self.len + 1], self.offsets[idx..self.len]);

            self.offsets[idx] = cell_idx;
            self.cells[cell_idx] = cell;
            // this cell already has the correct key, just change the page it points to
            self.cells[self.offsets[idx + 1]].next_page = right;

            self.len += 1;
        }

        /// Indicates the given idx in cells is free. No-op if idx > `fanout`
        fn available(self: *Self, idx: usize) void {
            const one: u32 = @intCast(1);
            self.header.freeblocks |= (one << @as(u5, @intCast(idx)));
            self.header.freeblocks &= Header.FREEBLOCK_MASK;
        }

        /// Retrieves the next available index in the page.
        fn nextFreeIdx(self: *Self) ?usize {
            return self.header.nextFreeIdxMut();
        }

        const Header = struct {
            const CellKind = enum {
                Internal,
                Leaf,
            };

            kind: CellKind,

            // each cell stores a pointer to the page where keys are lte than it.
            // here we take the sqlite approach and keep the next ptr in the header
            right_page: ?*Self = null,

            /// keeps track of available indexes in the page.cells array
            /// could make this a `comptime_int`
            freeblocks: u32 = 0,

            const internal: Header = .{ .kind = .Internal };
            const leaf: Header = .{ .kind = .Leaf };

            /// should be like [0,0,..1,1,..1] where @popCount(num) == fanout
            const FREEBLOCK_MASK: u32 = (1 << capacity) - 1;

            fn nextFreeIdxMut(self: *Header) ?usize {
                const ptr = &self.freeblocks;
                const mask = ptr.* & Header.FREEBLOCK_MASK;

                if (mask != 0) {
                    const i = @ctz(mask);
                    const one: u32 = @intCast(1);
                    // unset bit
                    ptr.* = mask & ~(one << @as(u5, @intCast(i)));
                    return i;
                }

                return null;
            }
        };

        const Cell = struct {
            key: k,
            // key_size: usize = @sizeOf(k),

            /// case: `CellKind.Leaf`
            value: ?v = null,

            /// case: `CellKind.Internal`
            /// each separator key has a child pointer, while the last pointer is
            /// stored separately, since it’s not paired with any key
            next_page: ?*Self = null,
        };

        const CmpHelpers = struct {
            const Ctx = struct { key: k, cells: []const Cell };

            fn lessThanFn(ctx: Ctx, lhs: usize, rhs: usize) bool {
                return ctx.cells[lhs].key < ctx.cells[rhs].key;
            }

            fn cmpKey(ctx: Ctx, offset: usize) std.math.Order {
                return std.math.order(ctx.key, ctx.cells[offset].key);
            }
        };

        const Traversal = struct {
            /// indicates whether we need crumbs or not
            mode: Mode,

            // FIXME: this gets replaced with a &PageManager
            // which can actually be an interface like `Allocator` ? 
            // -- this way we can use an in-memory testing allocator
            gpa: ?std.mem.Allocator = null,

            /// stores {ptr, split_idx} as a stack
            breadcrumbs: std.ArrayList(struct { *Self, usize }) = .empty,

            /// Traversal helper for binary search
            const Mode = enum {
                Insert,
                Search,
            };

            fn clearAndFree(self: *Traversal) void {
                self.breadcrumbs.clearAndFree(self.gpa.?);
            }

            fn empty(self: *Traversal) bool {
                return self.breadcrumbs.items.len == 0;
            }

            /// For a given depth retrieves the corresponding cell satisfying the needle query
            /// or returns none
            fn binarySearchCell(self: *Traversal, page: *Self, needle: k) ?Cell {
                _ = self;

                const offsets = page.offsetsSlice();
                const cells = page.cellsSlice();

                const idx = std.sort.binarySearch(
                    usize,
                    offsets,
                    CmpHelpers.Ctx{ .key = needle, .cells = cells },
                    CmpHelpers.cmpKey,
                ) orelse return null;

                return cells[offsets[idx]];
            }

            /// Finds the next page at depth N+1 to search for a given needle
            fn binarySearchPage(self: *Traversal, page: *Self, needle: k) !*Self {
                const offsets = page.offsetsSlice();
                const cells = page.cellsSlice();

                const offset_idx = std.sort.upperBound(
                    usize,
                    offsets,
                    CmpHelpers.Ctx{ .key = needle, .cells = cells },
                    CmpHelpers.cmpKey,
                );

                const found, const idx = blk: {
                    if (offset_idx < page.len) {
                        const cell_idx = offsets[offset_idx];
                        break :blk .{ cells[cell_idx].next_page.?, offset_idx };
                    }
                    // otherwise item is on the right
                    break :blk .{ page.rightPage().?, MAGIC_OFFSET };
                };

                switch (self.mode) {
                    .Insert => self.breadcrumbs.append(self.gpa.?, .{ page, idx }) catch return error.FailedToAllocate,
                    .Search => {},
                }

                return found;
            }
        };

        fn findLeaf(self: *Self, t: *Traversal, key: k) !*Self {
            const kind = self.header.kind;

            switch (kind) {
                .Leaf => return self,
                .Internal => {
                    const next = try t.binarySearchPage(self, key);
                    return next.findLeaf(t, key);
                },
            }
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, key: k, value: v) !*Self {
            var root = self;

            var t: Traversal = .{ .mode = .Insert, .gpa = gpa };
            defer t.clearAndFree();

            var leaf = try self.findLeaf(&t, key);

            if (leaf.full()) {
                const items = try leaf.splitCascade(gpa, &t);
                const right = items.new_page;

                if (right.firstCell().?.key > key) {
                    leaf = self;
                } else {
                    leaf = right;
                }

                // if we visited each breadcrumb we may have created a new root
                if (t.empty()) {
                    root = items.root;
                }
            }

            leaf.pushAssumeCapacity(.{ .key = key, .value = value });

            std.sort.heap(
                usize,
                leaf.offsets[0..leaf.len],
                CmpHelpers.Ctx{ .key = key, .cells = leaf.cellsSlice() },
                CmpHelpers.lessThanFn,
            );

            return root;
        }

        fn split(self: *Self, gpa: std.mem.Allocator) !struct { *Self, *Self } {
            if (!self.full()) return error.NoNeedToSplit;

            const kind = self.header.kind;
            const right = try gpa.create(Self);

            right.* = .{ .header = .{ .kind = kind } };

            // hacky @divCeil in zig 0.16
            const half: comptime_int = @divFloor(capacity, 2) + (capacity % 2);

            for (self.offsets[half..], 0..) |o, i| {
                right.cells[i] = self.cells[o];
                right.offsets[i] = i;
                self.available(o);
            }

            self.len = half;
            right.len = capacity - half;

            if (kind == .Internal) {
                right.header.right_page = self.header.right_page;

                const last_cell = self.lastCell().?;
                self.header.right_page = last_cell.next_page;
                self.available(self.len - 1);
                self.len -= 1;
            }

            return .{ self, right };
        }

        // FIXME: write tests for this when parents.full()
        fn splitCascade(self: *Self, gpa: std.mem.Allocator, t: *Traversal) !struct { root: *Self, new_page: *Self } {
            var root = self;

            const left, const right = try self.split(gpa);
            const crumb = t.breadcrumbs.pop();

            if (crumb == null) {
                // create a new SlottedPage with siblings
                root = try gpa.create(Self);
                root.* = .{
                    .header = .{
                        .kind = .Internal,
                        .right_page = right,
                    },
                    .len = 1,
                };
                root.offsets[0] = 0;
                root.cells[0] = .{
                    .key = right.firstCell().?.key,
                    .next_page = left,
                };

                return .{ .root = root, .new_page = right };
            }

            // otherwise use existing parent
            var parent, const idx = crumb.?;

            if (!parent.full()) {
                parent.insertSiblings(idx, left, right);
                root = parent;
            } else {
                const items = try parent.splitCascade(gpa, t);

                if (idx < parent.len) {
                    parent.insertSiblings(idx, left, right);
                } else {
                    items.new_page.insertSiblings(idx - parent.len, left, right);
                }
                root = items.root;
            }

            return .{ .root = root, .new_page = right };
        }

        pub fn get(self: *const Self, key: k) ?v {
            var t: Traversal = .{ .mode = .Search };

            // SAFETY: no allocations are done in search mode
            const self_mut: *Self = @constCast(self);
            const leaf = findLeaf(self_mut, &t, key) catch unreachable;

            std.debug.print("{any}\n", .{leaf});

            const cell = t.binarySearchCell(leaf, key) orelse return null;
            return cell.value.?;
        }
    };
}

test "ordering" {
    const Page = SlottedPage(3, i32, i32);

    const offsets: [3]usize = .{ 1, 2, 0 };
    const cells: [3]Page.Cell = .{
        .{ .key = 3, .value = 3 },
        .{ .key = 0, .value = 0 },
        .{ .key = 1, .value = 1 },
    };

    // search in the middle
    var idx = std.sort.upperBound(
        usize,
        offsets[0..],
        Page.CmpHelpers.Ctx{ .key = 2, .cells = cells[0..] },
        Page.CmpHelpers.cmpKey,
    );
    try std.testing.expectEqual(idx, 2);

    // search past the right
    idx = std.sort.upperBound(
        usize,
        offsets[0..],
        Page.CmpHelpers.Ctx{ .key = 4, .cells = cells[0..] },
        Page.CmpHelpers.cmpKey,
    );
    try std.testing.expectEqual(idx, 3);
}

test "splits on leaf node" {
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const gpa = allocator.allocator();

    const Page = SlottedPage(3, i32, i32);

    var root: Page = .{
        .header = .leaf,
        .offsets = .{ 1, 0, 2 },
        .cells = .{
            .{ .key = 1, .value = 1 },
            .{ .key = 0, .value = 0 },
            .{ .key = 2, .value = 2 },
        },
        .len = 3,
    };

    try std.testing.expect(root.full());

    const left, const right = try root.split(gpa);

    try std.testing.expectEqualSlices(usize, left.offsetsSlice(), &.{ 1, 0 });
    try std.testing.expectEqual(left.header.freeblocks, 4);
    try std.testing.expectEqual(left.cellsSlice()[1], Page.Cell{ .key = 0, .value = 0 });
    try std.testing.expectEqual(left.cellsSlice()[0], Page.Cell{ .key = 1, .value = 1 });

    try std.testing.expectEqualSlices(usize, right.offsetsSlice(), &.{0});
    try std.testing.expectEqual(right.header.freeblocks, 0);
    try std.testing.expectEqual(right.cellsSlice()[0], Page.Cell{ .key = 2, .value = 2 });
}

test "splits on internal node" {
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const gpa = allocator.allocator();

    const Page = SlottedPage(3, i32, i32);

    var right_page: Page = .empty;
    _ = try right_page.insert(gpa, 3, 3);

    var internal: Page = .{
        .header = .{
            .kind = .Internal,
            .right_page = &right_page,
        },
        .offsets = .{ 0, 1, 2 },
        .cells = .{
            .{ .key = 0 },
            .{ .key = 1 },
            .{ .key = 2 },
        },
        .len = 3,
    };

    try std.testing.expect(internal.full());

    const left, const right = try internal.split(gpa);

    try std.testing.expectEqualSlices(usize, left.offsetsSlice(), &.{0});
    try std.testing.expectEqual(left.header.freeblocks, 6);
    try std.testing.expectEqual(left.cellsSlice()[0], Page.Cell{ .key = 0 });
    // NOTE: should check that Page.Cell{.key = 1 } in left.header.right_page ...

    try std.testing.expectEqualSlices(usize, right.offsetsSlice(), &.{0});
    try std.testing.expectEqual(right.header.freeblocks, 0);
    try std.testing.expectEqual(right.cellsSlice()[0], Page.Cell{ .key = 2 });
    try std.testing.expectEqual(right.header.right_page, &right_page);
}

test "insert siblings" {
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const gpa = allocator.allocator();

    const Page = SlottedPage(2, i32, i32);

    // setup
    var left: Page = .empty;
    _ = try left.insert(gpa, 0, 0);
    _ = try left.insert(gpa, 1, 1);

    var right: Page = .empty;
    _ = try right.insert(gpa, 2, 2);
    _ = try right.insert(gpa, 3, 3);

    var root: Page = .{
        .header = .{
            .kind = .Internal,
            .right_page = &right,
        },
        .len = 1,
    };
    root.cells[0] = .{ .key = 2, .next_page = &left };
    root.offsets[0] = 0;

    // insert without touching right branch
    const left_left, const left_right = try left.split(gpa);
    try std.testing.expectEqual(root.firstCell().?.key, 2);
    root.insertSiblings(0, left_left, left_right);
    try std.testing.expectEqual(root.firstCell().?.key, 1);
    try std.testing.expectEqual(root.lastCell().?.key, 2);

    // pretend like we didn't do the above
    root.len -= 1;

    // okay now split the item on the right
    const right_left, const right_right = try right.split(gpa);
    root.insertSiblings(Page.MAGIC_OFFSET, right_left, right_right);
    try std.testing.expectEqual(root.lastCell().?.key, 3);
    try std.testing.expectEqual(root.lastCell().?.next_page, right_left);
    try std.testing.expectEqual(root.header.right_page, right_right);
}

// FIXME: write a test for splitCascade
test "split cascade" {}

// i. offset_idx == fanout (leaf was in right page of parent)
// WARN: I'm unsure this case is handled properly:
// ii. => we're in right sibling
test "split cascade with insert on far right" {}
