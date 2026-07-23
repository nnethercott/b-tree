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
// splitting
// - we can use the breadcrumbs to KNOW if a parent exists !
// - at each depth, perform a split and update the parent with the new pages
// - should it belong to the Traversal ? or another fn(self: *Self, t: *Traversal)?

// questions:
// - [fanout]Cell is presumably allocated on the stack; how then do we get page alignment and why does that matter?
// - ^for me its related to mmapping some data structure ? so that the corresponding pages bring in a SlottedPage

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const SlottedPage = slotted_page(2, i32, i32);

    var page: SlottedPage = .empty;
    try page.insert(allocator, 42, 1);
    try page.insert(allocator, 0, 12);

    std.debug.print("{any}\n", .{page.get(0)});
    std.debug.print("{any}\n", .{page.get(42)});

    std.debug.print("{any}", .{page});
}

fn slotted_page(comptime fanout: usize, comptime k: type, comptime v: type) type {
    return struct {
        header: Header,
        offsets: [fanout]Offset = undefined,
        cells: [fanout]Cell = undefined,
        idx: usize = 0,

        const Self = @This();
        const empty: Self = .{ .header = .{} };

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

        const Offset = struct {
            idx: usize,

            fn lessThanFn(ctx: struct { k, []const Cell }, lhs: Offset, rhs: Offset) bool {
                return ctx[1][lhs.idx].key < ctx[1][rhs.idx].key;
            }

            fn cmpKey(ctx: struct { k, []const Cell }, off: Offset) std.math.Order {
                return std.math.order(ctx[0], ctx[1][off.idx].key);
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

            fn assert_mode_ok(self: Traversal) !void {
                if (self.mode == .Insert and self.gpa == null) {
                    return error.MissingAllocator;
                }
            }

            fn binary_search_value(self: *Traversal, page: *const Self, needle: k) ?v {
                _ = self;

                const cells: []const Cell = page.cells[0..];

                const idx = std.sort.binarySearch(
                    Offset,
                    page.offsets[0..],
                    .{ needle, cells },
                    Offset.cmpKey,
                ) orelse return null;

                const where = page.offsets[idx];
                return page.cells[where.idx].value.?;
            }

            fn binary_search_page(self: *Traversal, page: *const Self, needle: k) !*Self {
                try self.assert_mode_ok();

                const cells: []const Cell = page.cells[0..];

                const offset_idx = std.sort.upperBound(
                    Offset,
                    page.offsets[0..],
                    .{ needle, cells },
                    Offset.cmpKey,
                );

                const found, const idx = blk: {
                    if (offset_idx < cells.len) {
                        const idx = page.offsets[offset_idx].idx;
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

        fn get_leaf_page(self: *Self, t: *Traversal, key: k) !*Self {
            const kind = self.header.kind;

            switch (kind) {
                .Leaf => return self,
                .Internal => {
                    const next = try t.binary_search_page(self, key);
                    return next.get_leaf_page(t, key);
                },
            }
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, key: k, value: v) !void {
            var t: Traversal = .{ .mode = .Insert, .gpa = gpa };
            var leaf = try self.get_leaf_page(&t, key);

            const next_idx = leaf.idx;

            if (next_idx == fanout) {
                // should split, checking the traversal breadcrumbs
                // self.split_recursive(&t, gpa);
                return error.OutOfBounds;
            }

            // NOTE: we're not doing left appends
            leaf.offsets[next_idx] = .{ .idx = next_idx };
            leaf.cells[next_idx] = .{ .key = key, .value = value };

            // FIXME: what if we always allocated here ? std.heap.FixedBufferAllocator.init(buffer: []u8)
            // and then kept this allocator local to the slotted page ?
            // still doesn't guarantee we'll get "append from right" behaviour
            // BUT: could use a fba on the corresponding slice to alloc...

            const cells: []const Cell = leaf.cells[0..];
            const offsets: []Offset = leaf.offsets[0..];

            std.sort.heap(
                Offset,
                offsets,
                .{ key, cells },
                Offset.lessThanFn,
            );

            leaf.idx += 1;
        }

        pub fn get(self: *const Self, key: k) ?v {
            var t: Traversal = .{ .mode = .Search };

            // no allocations are done in search mode
            const self_mut: *Self = @constCast(self);
            const leaf = get_leaf_page(self_mut, &t, key) catch unreachable;

            return t.binary_search_value(leaf, key);
        }

        fn split(self: *Self, gpa: std.mem.Allocator) !struct { left: *Self, right: ?*Self } {
            // happy path, no work
            if (self.idx < fanout) {
                return .{ .left = self, .right = null };
            }

            const left = self;

            // note: no defer gpa.destroy(sibling_ptr) as we're using an arena allocator
            const right = try gpa.create(Self);
            right.* = .empty;

            const half = @divFloor(fanout, 2);

            //  offsets
            const right_offsets = left.offsets[half..];
            @memcpy(right.offsets[0 .. fanout - half], right_offsets);
            left.idx = half;
            right.idx = fanout - half;

            // cells
            for (right_offsets, 0..) |off, i| {
                right.cells[i] = left.cells[off.idx];
                left.available(off.idx);
            }

            return .{ .left = left, .right = right };
        }
    };
}
