const std = @import("std");
const expect = std.testing.expect;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var page: SlottedPage = .empty;
    try page.insert(arena.allocator(), 42, 1);

    std.debug.print("{any}\n", .{page.get(0)});
    std.debug.print("{any}\n", .{page.get(42)});
}

const CellKind = enum {
    Internal,
    Leaf,
};
const Header = struct {
    kind: CellKind = .Leaf,

    // each cell stores a pointer to the page where keys are lte than it.
    // here we take the sqlite approach and keep the next ptr in the header
    right_ptr: ?*SlottedPage = null,

    // freeblocks: []usize
};

fn cell(k: type, v: type) type {
    return struct {
        key_size: usize = @sizeOf(k),
        key: k,

        /// case: `CellKind.Leaf`
        value: ?v = null,

        /// case: `CellKind.Internal`
        /// each separator key has a child pointer, while the last pointer is
        /// stored separately, since it’s not paired with any key
        next_page: ?*SlottedPage = null,

        const Self = @This();
    };
}

// FIXME: everything needs to be generic later
const i32Cell = cell(i32, i32);

const Offset = struct {
    offset: usize,

    fn lessThanFn(ctx: struct { i32, []i32Cell }, lhs: Offset, rhs: Offset) bool {
        return ctx[1][lhs.offset].key < ctx[1][rhs.offset].key;
    }

    fn cmpKey(ctx: struct { i32, []i32Cell }, off: Offset) std.math.Order {
        return std.math.order(ctx[0], ctx[1][off.offset].key);
    }
};

fn slotted_page(comptime fanout: usize, comptime k: type, comptime v: type) type {
    // NOTE: in a v1 we'll use the `fanout` as the ground truth for page size rather than the
    // "fit everythin into a page" approach

    return struct {
        header: Header,
        offsets: [fanout]cell(k, v) = .{},
        cells: [fanout]cell(k, v) = .{},
        offset: usize = 0,

        const Self = @This();
        const empty: Self = .{ .header = .{} };

        /// Traversal helper for binary search
        const Mode = enum {
            Insert,
            Search,
        };

        const Traversal = struct {
            /// indicates whether we need crumbs or not
            mode: Mode,

            gpa: ?std.mem.Allocator = null,

            /// stores {ptr, split_idx} as a stack
            breadcrumbs: std.ArrayList(struct { *Self, usize }) = .empty,

            fn assert_mode_ok(self: Traversal) !void {
                if (self.mode == .Insert and self.gpa == null) {
                    return error.MissingAllocator;
                }
            }

            fn binary_search_value(self: *Traversal, page: *const Self, needle: i32) ?i32 {
                _ = self;

                const idx = std.sort.binarySearch(
                    Offset,
                    page.offsets.items[0..],
                    .{ needle, page.cells.items[0..] },
                    Offset.cmpKey,
                ) orelse return null;

                const offset = page.offsets.items[idx];
                return page.cells.items[offset.offset].value.?;
            }

            fn binary_search_page(self: *Traversal, page: *const Self, needle: i32) !*Self {
                try self.assert_mode_ok();

                const offset_idx = std.sort.upperBound(
                    Offset,
                    page.offsets.items[0..],
                    .{ needle, page.cells.items[0..] },
                    Offset.cmpKey,
                );

                const found, const idx = blk: {
                    const cells = page.cells.items.len;

                    if (offset_idx < cells) {
                        const idx = page.offsets.items[offset_idx].offset;
                        break :blk .{ page.cells.items[idx].next_page.?, idx };
                    }
                    // otherwise item is on the right
                    break :blk .{ page.header.right_ptr.?, cells };
                };

                switch (self.mode) {
                    .Insert => self.breadcrumbs.append(self.gpa.?, .{ found, idx }) catch return error.FailedToAllocate,
                    .Search => {},
                }

                return found;
            }
        };

        fn insert(self: *Self, gpa: std.mem.Allocator, key: k, value: v) !void {
            const t: Traversal = .{ .mode = .Insert, .gpa = gpa };
            _ = t;

            // t.binary_search_page(self, k)

            if (self.offset == fanout) {
                return error.OutOfBounds;
            }

            // TODO: check if we're at capacity and SPLIT !
            try self.offsets.append(gpa, .{ .offset = self.offset });
            try self.cells.insert(gpa, 0, .{ .key = key, .value = value });

            // FIXME: what if we always allocated here ? std.heap.FixedBufferAllocator.init(buffer: []u8)
            // and then kept this allocator local to the slotted page ?
            // still doesn't guarantee we'll get "append from right" behaviour
            // BUT: could use a fba on the corresponding slice to alloc...

            // now reorder the self.offsets
            std.sort.heap(
                Offset,
                self.offsets.items[0..],
                .{ k, self.cells.items[0..] },
                Offset.lessThanFn,
            );

            self.offset += 1;
        }

        fn get(self: *const Self, key: i32) ?i32 {
            const kind = self.header.kind;
            var t: Traversal = .{ .mode = .Search };

            switch (kind) {
                .Leaf => return t.binary_search_value(self, key),
                .Internal => {
                    // we never allocate so this cannot fail
                    const next = t.binary_search_page(self, key) catch unreachable;
                    return next.get(key);
                },
            }
        }
    };
}
