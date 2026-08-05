const std = @import("std");

const Store = @This();

ptr: *anyopaque,
vtable: *const VTable,

const StoreError = error{Allocation};

pub const VTable = struct {
    store_fn: *const fn (*anyopaque, id: usize, bytes: []u8) StoreError!void,
    fetch_fn: *const fn (*anyopaque, id: usize) ?[]u8,
};

pub fn store(s: *Store, id: usize, bytes: []u8) StoreError!void {
    try s.vtable.store_fn(s.ptr, id, bytes);
}

pub fn fetch(s: *Store, id: usize) ?[]u8 {
    return s.vtable.fetch_fn(s.ptr, id);
}

// testing impl
const HashStore = struct {
    table: std.AutoHashMap(usize, []u8),

    fn init(gpa: std.mem.Allocator) HashStore {
        return .{ .table = .init(gpa) };
    }

    fn deinit(self: *HashStore) void {
        self.table.deinit();
    }

    fn hashStore(ptr: *anyopaque, id: usize, bytes: []u8) StoreError!void {
        var s: *HashStore = @ptrCast(@alignCast(ptr));
        s.table.put(id, bytes) catch return StoreError.Allocation;
    }

    fn hashFetch(ptr: *anyopaque, id: usize) ?[]u8 {
        var s: *HashStore = @ptrCast(@alignCast(ptr));
        return s.table.get(id);
    }

    fn store(self: *HashStore) Store {
        return .{
            .ptr = self,
            .vtable = &.{
                .store_fn = hashStore,
                .fetch_fn = hashFetch,
            },
        };
    }
};

test "hashstore works" {
    var hs: HashStore = .init(std.testing.allocator);
    defer hs.deinit();

    var in_memory_store: Store = hs.store();

    const foo = .{ .baz = "bar" };
    const bytes: []u8 = @ptrCast(@constCast(&foo));

    try in_memory_store.store(42, bytes);
    const value = in_memory_store.fetch(42);

    try std.testing.expectEqualSlices(u8, value.?, bytes);
    const oof: *@TypeOf(foo) = @ptrCast(value.?);
    try std.testing.expectEqual(oof.baz, foo.baz);
}
