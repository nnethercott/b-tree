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

        // FIXME: we don't need offsets as a struct, lets refacto
        offsets: [fanout]usize = undefined,
        cells: [fanout]Cell = undefined,
        idx: usize = 0,

        const Self = @This();
        const empty: Self = .{ .header = .{} };

        fn first_key(self: Self) ?k {
            // if (self.cells == null) {
            //     return null;
            // }

            return self.cells[self.offsets[0]].key;
        }

        fn insertAssumeCapacity(self: *Self, idx: usize, cell: Cell) void {
            _ = self;
            _ = idx;
            _ = cell;
            // @memcpy some stuff and insert the cell
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

            const PageOrValue = union { value: v, page: *Self };

            fn assert_mode_ok(self: Traversal) !void {
                if (self.mode == .Insert and self.gpa == null) {
                    return error.MissingAllocator;
                }
            }

            fn free(self: *Traversal) void {
                self.breadcrumbs.clearAndFree(self.gpa.?);
            }

            /// For a given depth retrieves the corresponding cell satisfying the needle query
            /// or returns none
            fn binary_search_cell(self: *Traversal, page: *const Self, needle: k) ?Cell {
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
            fn binary_search_page(self: *Traversal, page: *const Self, needle: k) !*Self {
                try self.assert_mode_ok();

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

        fn find_leaf(self: *Self, t: *Traversal, key: k) !*Self {
            const kind = self.header.kind;

            switch (kind) {
                .Leaf => return self,
                .Internal => {
                    const next = try t.binary_search_page(self, key);
                    return next.find_leaf(t, key);
                },
            }
        }

        pub fn insert(self: *Self, gpa: std.mem.Allocator, key: k, value: v) !void {
            var t: Traversal = .{ .mode = .Insert, .gpa = gpa };
            defer t.free();

            var leaf = try self.find_leaf(&t, key);
            const next_idx = leaf.idx;

            // FIXME: replace this and the parent one with try_split(gpa, &t)
            if (next_idx == fanout) {
                const siblings = try self.split(gpa, &t);
                _ = siblings;
            }

            // NOTE: we're not doing left appends
            leaf.offsets[next_idx] = next_idx;
            leaf.cells[next_idx] = .{ .key = key, .value = value };

            const cells: []const Cell = leaf.cells[0..];
            const offsets: []usize = leaf.offsets[0..];

            std.sort.heap(
                usize,
                offsets,
                .{ key, cells },
                CmpHelpers.lessThanFn,
            );

            leaf.idx += 1;
        }

        fn split(self: *Self, gpa: std.mem.Allocator, t: *Traversal) !struct { left: *Self, right: *Self } {
            expect(self.idx < fanout) catch return error.NoNeedToSplit;

            const left = self;

            // NOTE: no defer gpa.destroy(sibling_ptr) as we're using an arena allocator
            const right = try gpa.create(Self);
            right.* = .empty;

            const half = @divFloor(fanout, 2);

            //  offsets
            const right_offsets = left.offsets[half..];
            @memcpy(right.offsets[0 .. fanout - half], right_offsets);
            left.idx = half;
            right.idx = fanout - half;

            // cells
            for (right_offsets, 0..) |o, i| {
                right.cells[i] = left.cells[o];
                left.available(o);
            }

            // FIXME: we should switch on here; if NO parent exists then we're in the leaf and NEED a new parent !
            // maybe we do a parent = if{} else{} ...
            if (t.breadcrumbs.pop()) |crumb| {
                const parent, const idx = crumb;

                switch (parent.idx) {
                    fanout => _ = try parent.split(gpa, t),
                    else => _ = parent.insertAssumeCapacity(idx, .{
                        .key = right.first_key().?,
                        .next_page = right,
                    }),
                }
            }

            return .{ .left = left, .right = right };
        }

        pub fn get(self: *const Self, key: k) ?v {
            var t: Traversal = .{ .mode = .Search };

            // no allocations are done in search mode
            const self_mut: *Self = @constCast(self);
            const leaf = find_leaf(self_mut, &t, key) catch unreachable;

            const cell = t.binary_search_cell(leaf, key) orelse return null;
            return cell.value.?;
        }
    };
}
