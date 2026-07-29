const std = @import("std");
const expect = std.testing.expect;

// NOTE: few things i don't like
// - @constCast due to find_leaf_page
// - everything in one tightly coupled generic fn

// TODO:
//
// allocation
// fba in a slice to page align ? std.heap.FixedBufferAllocator.init(buffer: []u8)
// and then kept this allocator local to the slotted page ?
// still doesn't guarantee we'll get "append from right" behaviour
// BUT: could use a fba on the corresponding slice to alloc...

// questions:
// - [fanout]Cell is presumably allocated on the stack; how then do we get page alignment and why does that matter?
//    - ^for me its related to mmapping some data structure ? so that the corresponding pages bring in a SlottedPage
// - (zig question) defer "Executes an expression unconditionally at scope exit."
//    => if we put this in a test helper we'd free the memory before running, no ?

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Page = SlottedPage(4, i32, i32);

    var page: Page = .empty;
    try page.insert(allocator, 2, 2);
    try page.insert(allocator, 0, 0);
    try page.insert(allocator, 3, 3);
    try page.insert(allocator, 1, 1);

    std.debug.print("{any}\n", .{page.get(0)});
    std.debug.print("{any}\n", .{page.get(1)});
    // std.debug.print("{any}\n", .{page.get(2)});
    std.debug.print("{any}", .{page});
}

pub fn SlottedPage(comptime fanout: usize, comptime k: type, comptime v: type) type {
    // FIXME: comptime fn() comptime_int returning fanout from k, v as a default value
    // FIXME: add signature like .init(gpa, &cmpKey) ?

    return struct {
        header: Header,
        offsets: [fanout]usize = undefined,
        cells: [fanout]Cell = undefined,
        len: usize = 0,

        const Self = @This();
        pub const empty: Self = .{ .header = .leaf };

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
                .Leaf => return self.len == fanout,
                .Internal => return (self.len == fanout and self.header.right_page != null),
            }
            return self.len == fanout;
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

        /// Inserts a cell at a specific position in the page, or in the header if at capacity.
        /// The insertion `idx` is assumed to be such that cell ordering is preserved
        fn insertAssumeOrdered(self: *Self, idx: usize, cell: Cell) void {
            if (self.len == fanout) {
                if (idx == fanout) {
                    self.header.right_page = cell.next_page;
                    return;
                }

                self.header.right_page = self.lastCell().?.next_page;

                // SAFETY: this signals in the subsequent op that the cell we just copied
                // over can be overwritten. We take the convention that insertion into the
                // right_page doesn't change `self.len`
                self.len -= 1;
            }

            // shift offsets to the right by 1
            @memcpy(self.offsets[idx + 1 .. self.len + 1], self.offsets[idx..self.len]);

            const cell_idx = self.nextFreeIdx() orelse self.len;

            self.offsets[idx] = cell_idx;
            self.cells[cell_idx] = cell;
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
            const FREEBLOCK_MASK: u32 = (1 << fanout) - 1;

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

            /// For a given depth retrieves the corresponding cell satisfying the needle query
            /// or returns none
            fn binarySearchCell(self: *Traversal, page: *const Self, needle: k) ?Cell {
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
            fn binarySearchPage(self: *Traversal, page: *const Self, needle: k) !*Self {
                const offsets = page.offsetsSlice();
                const cells = page.cellsSlice();

                const offset_idx = std.sort.upperBound(
                    usize,
                    offsets,
                    CmpHelpers.Ctx{ .key = needle, .cells = cells },
                    CmpHelpers.cmpKey,
                );

                const found, const idx = blk: {
                    if (offset_idx < fanout) {
                        const cell_idx = offsets[offset_idx];
                        break :blk .{ cells[cell_idx].next_page.?, offset_idx };
                    }
                    // otherwise item is on the right
                    break :blk .{ page.rightPage().?, fanout };
                };

                switch (self.mode) {
                    .Insert => self.breadcrumbs.append(self.gpa.?, .{ found, idx }) catch return error.FailedToAllocate,
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

        pub fn insert(self: *Self, gpa: std.mem.Allocator, key: k, value: v) !void {
            var t: Traversal = .{ .mode = .Insert, .gpa = gpa };
            defer t.clearAndFree();

            var leaf = try self.findLeaf(&t, key);

            if (leaf.full()) {
                std.debug.print("splitting\n", .{});
                const siblings = try leaf.splitCascade(gpa, &t);

                if (siblings.right.firstCell().?.key > key) {
                    leaf = siblings.left;
                } else {
                    leaf = siblings.right;
                }
            }

            leaf.pushAssumeCapacity(.{ .key = key, .value = value });

            std.sort.heap(
                usize,
                leaf.offsets[0..self.len],
                CmpHelpers.Ctx{ .key = key, .cells = leaf.cellsSlice() },
                CmpHelpers.lessThanFn,
            );
        }

        const Siblings = struct { left: *Self, right: *Self };

        fn split(self: *Self, gpa: std.mem.Allocator) !Siblings {
            expect(self.len == fanout) catch return error.NoNeedToSplit;

            const left = self;
            const right = try gpa.create(Self);

            right.* = .{ .header = .{ .kind = left.header.kind } };

            const half = @divFloor(fanout, 2);

            for (left.offsets[half..], 0..) |o, i| {
                right.cells[i] = left.cells[o];
                right.offsets[i] = i;
                left.available(o);
            }

            left.len = half;
            right.len = fanout - half;

            // We follow convention from the book which states "“The split point key is promoted to the parent”
            if (left.rightPage()) |page| {
                right.pushAssumeCapacity(
                    .{ .key = page.firstCell().?.key, .next_page = page },
                );
                left.header.right_page = null;
            }

            return .{ .left = left, .right = right };
        }

        // NOTE: we're still not doing anything with new roots ! we should promote them somewhere, new nodes
        // created here are floating around untracked
        fn splitCascade(self: *Self, gpa: std.mem.Allocator, t: *Traversal) !Siblings {
            const siblings = try self.split(gpa);
            const right = siblings.right;

            var parent, var offset_idx = t.breadcrumbs.pop() orelse blk: {
                const root = try gpa.create(Self);
                root.* = .{ .header = .internal };
                break :blk .{ root, 0 };
            };

            const cell: Cell = .{
                .key = right.firstCell().?.key,
                .next_page = right,
            };

            if (parent.full()) {
                const parents = try parent.splitCascade(gpa, t);
                const side = if (offset_idx < parents.left.len)
                    parents.left
                else blk: {
                    offset_idx -= parents.left.len;
                    break :blk parents.right;
                };
                side.insertAssumeOrdered(offset_idx, cell);
            } else {
                parent.insertAssumeOrdered(offset_idx, cell);
            }

            return siblings;
        }

        pub fn get(self: *const Self, key: k) ?v {
            var t: Traversal = .{ .mode = .Search };

            // SAFETY: no allocations are done in search mode
            const self_mut: *Self = @constCast(self);
            const leaf = findLeaf(self_mut, &t, key) catch unreachable;

            const cell = t.binarySearchCell(leaf, key) orelse return null;
            return cell.value.?;
        }
    };
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

    const siblings = try root.split(gpa);
    const left = siblings.left;
    const right = siblings.right;

    try std.testing.expectEqualSlices(usize, left.offsetsSlice(), &.{1});
    try std.testing.expectEqual(left.header.freeblocks, 5);
    try std.testing.expectEqual(left.cellsSlice()[1], Page.Cell{ .key = 0, .value = 0 });

    try std.testing.expectEqualSlices(usize, right.offsetsSlice(), &.{ 0, 1 });
    try std.testing.expectEqual(right.header.freeblocks, 0);
    try std.testing.expectEqual(right.cellsSlice()[0], Page.Cell{ .key = 1, .value = 1 });
    try std.testing.expectEqual(right.cellsSlice()[1], Page.Cell{ .key = 2, .value = 2 });
}

test "splits on internal node" {
    var allocator: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer allocator.deinit();
    const gpa = allocator.allocator();

    const Page = SlottedPage(3, i32, i32);

    var right_page: Page = .empty;
    try right_page.insert(gpa, 3, 3);

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

    const siblings = try internal.split(gpa);
    const left = siblings.left;
    const right = siblings.right;

    try std.testing.expectEqualSlices(usize, left.offsetsSlice(), &.{0});
    try std.testing.expectEqual(left.header.freeblocks, 6);
    try std.testing.expectEqual(left.cellsSlice()[0], Page.Cell{ .key = 0 });

    try std.testing.expectEqualSlices(usize, right.offsetsSlice(), &.{ 0, 1, 2 });
    try std.testing.expectEqual(right.header.freeblocks, 0);
    try std.testing.expectEqual(right.cellsSlice()[0], Page.Cell{ .key = 1 });
    try std.testing.expectEqual(right.cellsSlice()[1], Page.Cell{ .key = 2 });
    try std.testing.expectEqual(right.cellsSlice()[2], Page.Cell{ .key = 3, .next_page = &right_page });
}

test "inserts at capacity and ordered" {
    const Page = SlottedPage(3, i32, i32);

    var root: Page = .{ .header = .internal };
    root.offsets[0..2].* = .{ 0, 1 };
    root.cells[0..2].* = .{ .{ .key = 0 }, .{ .key = 1 } };
    root.len = 2;

    // insert with room in self.cells
    var cell: Page.Cell = .{ .key = 2 };
    root.insertAssumeOrdered(2, cell);
    try std.testing.expectEqualSlices(usize, root.offsetsSlice(), &.{ 0, 1, 2 });
    try std.testing.expectEqual(root.lastCell().?, cell);

    // insert and occupy header.right_page
    var leaf: Page = .{ .header = .leaf };
    leaf.offsets[0] = 0;
    leaf.cells[0] = .{ .key = 4, .value = 4 };
    leaf.len = 1;

    cell = .{ .key = leaf.firstCell().?.key, .next_page = &leaf };
    try std.testing.expectEqual(root.rightPage(), null);
    root.insertAssumeOrdered(3, cell);
    try std.testing.expectEqual(root.rightPage(), &leaf);

    // Insert but shift rightmost cell into header
    // Setup:
    // - replace last cell in `root` with the (cell, (leaf)) node
    // - clear out right page
    // - insert new element BEFORE `root.len`
    // => cell in last slot should get bumped to the right
    root.header.right_page = null;
    root.cells[2] = cell;
    root.insertAssumeOrdered(2, .{ .key = 3 });
    try std.testing.expectEqual(root.cellsSlice()[2], Page.Cell{ .key = 3 });
    try std.testing.expectEqual(root.rightPage(), &leaf);
}

// FIXME: write a test for splitCascade
// WARN: I'm unsure this case is handled properly:
// i. offset_idx == fanout (leaf was in right page of parent)
// ii. => we're in right sibling
// FIXME: add test for inserts where we check node
// try root.insert(gpa, 1, 1);
// try root.insert(gpa, 0, 0);
// try root.insert(gpa, 2, 2);
// FIXME: test traversal
