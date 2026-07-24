const std = @import("std");
const expect = std.testing.expect;

// NOTE: few things i don't like
// - @constCast due to find_leaf_page
// - everything in one tightly coupled generic fn

// TODO:
// freelist impl;
// - store available idx cells in a header field
// - make offset id for inserted the freelist.first
// - only search over non-deleted cells
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
    try page.insert(allocator, 42, 1);
    try page.insert(allocator, 0, 12);

    std.debug.print("{any}\n", .{page.get(0)});
    std.debug.print("{any}\n", .{page.get(42)});

    std.debug.print("{any}", .{page});
}

fn SlottedPage(comptime fanout: usize, comptime k: type, comptime v: type) type {
    return struct {
        header: Header,

        // FIXME: we don't need offsets as a struct, lets refacto
        offsets: [fanout]usize = undefined,
        cells: [fanout]Cell = undefined,
        len: usize = 0,

        const Self = @This();
        const empty: Self = .{ .header = .{} };

        fn firstKey(self: Self) ?k {
            // if (self.cells == null) {
            //     return null;
            // }

            return self.cells[self.offsets[0]].key;
        }

        fn insertAssumeOrdered(self: *Self, idx: usize, cell: Cell) void {
            @memcpy(self.offsets[idx + 1 .. self.len + 1], self.offsets[idx..self.len]);
            // FIXME: replace all instances of self.len with self.next_idx()
            self.cells[self.len] = cell;
            self.len += 1;
        }

        const Header = struct {
            const CellKind = enum {
                Internal,
                Leaf,
            };

            kind: CellKind = .Leaf,

            // each cell stores a pointer to the page where keys are lte than it.
            // here we take the sqlite approach and keep the next ptr in the header
            right_ptr: ?*Self = null,

            // keeps track of cells which are stale
            // freeblocks: [fanout]usize = undefined,
        };

        const Cell = struct {
            key_size: usize = @sizeOf(k),
            key: k,

            /// case: `CellKind.Leaf`
            value: ?v = null,

            /// case: `CellKind.Internal`
            /// each separator key has a child pointer, while the last pointer is
            /// stored separately, since it’s not paired with any key
            next_page: ?*Self = null,
        };

        const CmpHelpers = struct {
            fn lessThanFn(ctx: struct { k, []const Cell }, lhs: usize, rhs: usize) bool {
                return ctx[1][lhs].key < ctx[1][rhs].key;
            }

            fn cmpKey(ctx: struct { k, []const Cell }, off: usize) std.math.Order {
                return std.math.order(ctx[0], ctx[1][off].key);
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

                const idx = std.sort.binarySearch(
                    usize,
                    page.offsets[0..],
                    .{ needle, cells },
                    CmpHelpers.cmpKey,
                ) orelse return null;

                return page.cells[page.offsets[idx]];
            }

            /// Finds the next page at depth N+1 to search for a given needle
            fn binarySearchPage(self: *Traversal, page: *const Self, needle: k) !*Self {
                try self.assertModeOk();

                const cells: []const Cell = page.cells[0..];

                const offset_idx = std.sort.upperBound(
                    usize,
                    page.offsets[0..],
                    .{ needle, cells },
                    CmpHelpers.cmpKey,
                );

                const found, const idx = blk: {
                    if (offset_idx < cells.len) {
                        const idx = page.offsets[offset_idx];
                        break :blk .{ page.cells[idx].next_page.?, idx };
                    }
                    // otherwise item is on the right
                    break :blk .{ page.header.right_ptr.?, cells.len };
                };

                switch (self.mode) {
                    .Insert => self.breadcrumbs.append(self.gpa.?, .{ found, idx }) catch return error.FailedToAllocate,
                    .Search => {},
                }

                return found;
            }
        };

        /// indicates the given idx in cells is free
        fn available(self: *Self, idx: usize) void {
            _ = self;
            _ = idx;
        }

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
            const end = leaf.len;

            // FIXME: replace this and the parent one with try_split(gpa, &t)
            if (end == fanout) {
                const siblings = try self.splitRecursive(gpa, &t);
                _ = siblings;
            }

            // NOTE: we're not doing left appends
            leaf.offsets[end] = end;
            leaf.cells[end] = .{ .key = key, .value = value };

            const cells: []const Cell = leaf.cells[0..];
            const offsets: []usize = leaf.offsets[0..];

            std.sort.heap(
                usize,
                offsets,
                .{ key, cells },
                CmpHelpers.lessThanFn,
            );

            leaf.len += 1;
        }

        const Siblings = struct { left: *Self, right: *Self };

        // FIXME: we have a massive problem here !
        // when doing right.cells[i] = left.cells[o] we're filling in the old spots,
        // so subsequent insertions will either overwrite existing cells OR trigger segfault
        // -> we need the free list
        // IDEA: we can store the free list as a bitpacked thing as a single u32
        // then when we split the right gets ~freelist
        fn split(self: *Self, gpa: std.mem.Allocator) !Siblings {
            expect(self.len >= fanout) catch return error.NoNeedToSplit;

            const left = self;
            const right = try gpa.create(Self);
            right.* = .empty;

            const half = @divFloor(fanout, 2);

            //  offsets
            const right_offsets = left.offsets[half..];
            @memcpy(right.offsets[0 .. fanout - half], right_offsets);
            left.len = half;
            right.len = fanout - half;

            // cells
            for (right_offsets, 0..) |o, i| {
                right.cells[i] = left.cells[o];
                left.available(o);
                // right.available(compliment of left available cause of symmetry)
            }

            return .{ .left = left, .right = right };
        }

        fn splitRecursive(self: *Self, gpa: std.mem.Allocator, t: *Traversal) !Siblings {
            const siblings = try self.split(gpa);

            var parent, var idx = t.breadcrumbs.pop() orelse blk: {
                const root = try gpa.create(Self);
                root.* = .empty;
                break :blk .{ root, 0 };
            };

            // hmmmm we need to check which parent we go in
            // also that index we had before might be invalidated if we split
            // NOTE: there was a note in the book about this i think (knowing which side)
            const right = siblings.right;
            const cell: Cell = .{
                .key = right.firstKey().?,
                .next_page = right,
            };

            switch (parent.len) {
                fanout => {
                    const parents = try parent.split(gpa);

                    const side = if (idx < parents.left.len)
                        parents.left
                    else blk: {
                        idx -= parents.left.len;
                        break :blk parents.right;
                    };

                    side.insertAssumeOrdered(idx, cell);
                },

                else => parent.insertAssumeOrdered(idx, cell),
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
