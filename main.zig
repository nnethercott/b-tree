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

const SlottedPage = struct {
    header: Header,
    offsets: std.ArrayList(Offset) = .empty,
    cells: std.ArrayList(cell(i32, i32)) = .empty,
    offset: usize = 0,

    // fanout: usize

    const Self = @This();
    const empty: Self = .{ .header = .{} };

    fn insert(self: *Self, gpa: std.mem.Allocator, k: i32, v: i32) !void {
        // TODO: check if we're at capacity and SPLIT !
        try self.offsets.append(gpa, .{ .offset = self.offset });
        try self.cells.insert(gpa, 0, .{ .key = k, .value = v });

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

        switch (kind) {
            .Leaf => return binary_search_value(self, key),
            .Internal => {
                const next = binary_search_page(self, key);
                return next.get(key);
            },
        }
    }
};

fn binary_search_value(page: *const SlottedPage, needle: i32) ?i32 {
    expect(page.header.kind == .Leaf) catch unreachable;

    const idx = std.sort.binarySearch(
        Offset,
        page.offsets.items[0..],
        .{ needle, page.cells.items[0..] },
        Offset.cmpKey,
    ) orelse return null;

    const offset = page.offsets.items[idx];
    return page.cells.items[offset.offset].value.?;
}

fn binary_search_page(page: *const SlottedPage, needle: i32) *SlottedPage {
    expect(page.header.kind == .Internal) catch unreachable;

    const offset_idx = std.sort.upperBound(
        Offset,
        page.offsets.items[0..],
        .{ needle, page.cells.items[0..] },
        Offset.cmpKey,
    );

    if (offset_idx < page.cells.items.len) {
        const idx = page.offsets.items[offset_idx].offset;
        return page.cells.items[idx].next_page.?;
    }

    // otherwise item is on the right
    return page.header.right_ptr.?;
}
