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
// - ^for me its related to mmapping some data structure ? so that the corresponding pages bring in a SlottedPage

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

fn SlottedPage(comptime fanout: usize, comptime k: type, comptime v: type) type {
    return struct {
        header: Header,
        offsets: [fanout]usize = undefined,
        cells: [fanout]Cell = undefined,
        len: usize = 0,

        const Self = @This();
        const empty: Self = .{ .header = .leaf };

        fn firstKey(self: Self) ?k {
            if (self.len == 0) {
                return null;
            }
            return self.cells[self.offsets[0]].key;
        }

        fn lastKey(self: Self) ?k {
            if (self.len == 0) {
                return null;
            }
            return self.cells[self.offsets[self.len - 1]].key;
        }

        fn rightPage(self: Self) ?*Self {
            return self.header.right_page;
        }

        fn full(self: Self) bool {
            switch (self.header.kind) {
                .Leaf => return self.len == fanout,
                .Internal => return (self.len == fanout and self.header.right_page != null),
            }
            return self.len == fanout;
        }

        fn insertAssumeOrdered(self: *Self, idx: usize, cell: Cell) void {
            @memcpy(self.offsets[idx + 1 .. self.len + 1], self.offsets[idx..self.len]);
            // FIXME: replace all instances of self.len with self.next_idx()
            self.cells[self.len] = cell;
            self.len += 1;
        }

        /// Indicates the given idx in cells is free
        fn available(self: *Self, idx: usize) void {
            const one: @TypeOf(self.header.freeblocks) = @intCast(1);
            self.header.freeblocks |= (one << @as(u5, @intCast(idx)));
        }

        // Retrieves the next available index in the page.
        fn nextFreeIdx(self: *Self) ?usize {
            // TODO: do smth with fanout as a protective measure
            // so mask= freeblocks + 1 splat(fanout) and 0's above
            const ptr = &self.header.freeblocks;
            const mask = ptr.*;

            if (mask != 0) {
                const i = @ctz(mask);
                const one: u32 = @intCast(1);
                ptr.* = mask & ~(one << @as(u5, @intCast(i)));
                return i;
            }

            return null;
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

            fn cmpKey(ctx: Ctx, off: usize) std.math.Order {
                return std.math.order(ctx.key, ctx.cells[off].key);
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

            fn assertModeOk(self: Traversal) !void {
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

                const cells: []const Cell = page.cells[0..];
                const offsets: []const usize = page.offsets[0..page.len];

                const idx = std.sort.binarySearch(
                    usize,
                    offsets,
                    CmpHelpers.Ctx{ .key = needle, .cells = cells },
                    CmpHelpers.cmpKey,
                ) orelse return null;

                return page.cells[page.offsets[idx]];
            }

            /// Finds the next page at depth N+1 to search for a given needle
            fn binarySearchPage(self: *Traversal, page: *const Self, needle: k) !*Self {
                try self.assertModeOk();

                const cells: []const Cell = page.cells[0..];
                const offsets: []const usize = page.offsets[0..page.len];

                const offset_idx = std.sort.upperBound(
                    usize,
                    offsets,
                    CmpHelpers.Ctx{ .key = needle, .cells = cells },
                    CmpHelpers.cmpKey,
                );

                const found, const idx = blk: {
                    if (offset_idx < cells.len) {
                        const cell_idx = page.offsets[offset_idx];
                        break :blk .{ page.cells[cell_idx].next_page.?, offset_idx };
                    }
                    // otherwise item is on the right
                    break :blk .{ page.rightPage().?, cells.len };
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

                if (siblings.right.firstKey().? > key) {
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

            // NOTE: this only works if the key is numeric :// for + 1
            // if (left.rightPage()) |page| {
            //     const idx = right.nextFreeIdx().?;
            //     right.cells[idx] = .{ .key = right.lastKey().?, .next_page = page };
            //     left.header.right_page = null;
            // }

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
                .key = right.firstKey().?,
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
            } else if (parent.len == fanout) {
                parent.header.right_page = right;
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
