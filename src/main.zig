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
//    => if we put this in a helper we'd free the memory before running, no ?

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Page = SlottedPage(2, i32, i32);

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

        fn insertAssumeOrdered(self: *Self, idx: usize, cell: Cell) void {
            if (self.len == fanout) {
                if (idx == fanout) {
                    self.header.right_page = cell.next_page;
                    return;
                }

                const last_cell = self.lastCell().?;
                self.header.right_page = last_cell.next_page;

                // SAFETY: this signals in the subsequent op that the cell we just copied
                // over can be overwritten. We take the convention that insertion into the
                // right_page doesn't change `self.len`
                self.len -= 1;
            }

            @memcpy(self.offsets[idx + 1 .. self.len + 1], self.offsets[idx..self.len]);
            // FIXME: replace all instances of self.len with self.next_idx()
            self.cells[self.len] = cell;
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

            fn assertModeOk(self: *const Traversal) !void {
                if (self.mode == .Insert and self.gpa == null) {
                    return error.MissingAllocator;
                }
            }

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
                try self.assertModeOk();

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

            const cell_idx = leaf.nextFreeIdx() orelse self.len;
            leaf.offsets[leaf.len] = cell_idx;
            leaf.cells[cell_idx] = .{ .key = key, .value = value };

            leaf.len += 1;

            const cells: []const Cell = leaf.cells[0..];
            const offsets: []usize = leaf.offsets[0..self.len];

            std.sort.heap(
                usize,
                offsets,
                CmpHelpers.Ctx{ .key = key, .cells = cells },
                CmpHelpers.lessThanFn,
            );
        }

        const Siblings = struct { left: *Self, right: *Self };

        fn split(self: *Self, gpa: std.mem.Allocator) !Siblings {
            expect(self.len == fanout) catch return error.NoNeedToSplit;

            const left = self;
            const right = try gpa.create(Self);
            // defer gpa.destroy(right);

            right.* = .{ .header = .{ .kind = left.header.kind } };

            const half = @divFloor(fanout, 2);

            //  offsets
            const right_offsets = left.offsets[half..];
            @memcpy(right.offsets[0 .. fanout - half], right_offsets);
            left.len = half;
            right.len = fanout - half;

            // cells
            for (right_offsets) |o| {
                right.cells[o] = left.cells[o];
                left.available(o);
            }
            for (left.offsets[0..half]) |o| {
                right.available(o);
            }

            // case: kind = .Internal and we have a right page set in the header
            // we follow convention from the book which states "“The split point key is promoted to the parent”
            // => page.firstKey() inserted into right
            // SAFETY: this only gets called on internal nodes so page.firstKey() always non null

            // FIXME: left.popRightPage() ?*Self
            //FIXME: clean this
            if (left.rightPage()) |page| {
                const idx = right.nextFreeIdx().?;
                right.cells[idx] = .{ .key = page.firstCell().?.key, .next_page = page };
                right.offsets[right.len] = idx;
                right.len += 1;
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

                // TODO: write a test for this
                // WARN: I'm unsure this case is handled properly:
                // i. offset_idx == fanout (leaf was in right page of parent)
                // ii. => we're in right sibling
                // iii. => is offset_idx - parents.left.len valid ? or will it overwrite
                //         data from insertAssumeOrdered ?
                side.insertAssumeOrdered(offset_idx, cell);
            } else {
                parent.insertAssumeOrdered(offset_idx, cell);
            }

            return siblings;
        }

        pub fn get(self: *const Self, key: k) ?v {
            var t: Traversal = .{ .mode = .Search };

            // no allocations are done in search mode
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

    var root: Page = .empty;
    try root.insert(gpa, 1, 1);
    try root.insert(gpa, 0, 0);
    try root.insert(gpa, 2, 2);

    try std.testing.expect(root.full());

    const siblings = try root.split(gpa);
    const left = siblings.left;
    const right = siblings.right;

    try std.testing.expectEqualSlices(usize, left.offsetsSlice(), &.{1});
    try std.testing.expectEqual(left.header.freeblocks, 5);
    try std.testing.expectEqual(left.cellsSlice()[1], Page.Cell{ .key = 0, .value = 0 });

    try std.testing.expectEqualSlices(usize, right.offsetsSlice(), &.{ 0, 2 });
    try std.testing.expectEqual(right.header.freeblocks, 2);
    try std.testing.expectEqual(right.cellsSlice()[0], Page.Cell{ .key = 1, .value = 1 });
    try std.testing.expectEqual(right.cellsSlice()[2], Page.Cell{ .key = 2, .value = 2 });
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

    try std.testing.expectEqualSlices(usize, right.offsetsSlice(), &.{ 1, 2, 0 });
    try std.testing.expectEqual(right.header.freeblocks, 0);
    try std.testing.expectEqual(right.cellsSlice()[1], Page.Cell{ .key = 1 });
    try std.testing.expectEqual(right.cellsSlice()[2], Page.Cell{ .key = 2 });
    try std.testing.expectEqual(right.cellsSlice()[0], Page.Cell{ .key = 3, .next_page = &right_page });
}
