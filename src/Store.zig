const std = @import("std");

const Store = @This();

ptr: *anyopaque,
vtable: *const VTable,

const StoreError = error{Allocation};

pub const KV = struct {
    key: usize,
    bytes: []u8,
};

pub const VTable = struct {
    alloc: *const fn (*anyopaque) StoreError!KV,
    fetch: *const fn (*anyopaque, id: usize) ?[]u8,
};

pub fn alloc(s: *Store) StoreError!KV {
    return s.vtable.alloc(s.ptr);
}

pub fn fetch(s: *Store, id: usize) ?[]u8 {
    return s.vtable.fetch(s.ptr, id);
}

// testing impl
fn hash_store(T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        next_id: usize = 0,
        table: std.AutoHashMapUnmanaged(usize, []u8),

        const Self = @This();

        fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .table = .empty };
        }

        fn deinit(self: *Self) void {
            var iter = self.table.iterator();
            while (iter.next()) |item| {
                self.allocator.free(item.value_ptr.*);
            }
            self.table.deinit(self.allocator);
        }

        fn alloc(ptr: *anyopaque) StoreError!KV {
            var self: *Self = @ptrCast(@alignCast(ptr));

            const bytes = self.allocator.alloc(u8, @sizeOf(T)) catch return StoreError.Allocation;
            const id = self.next_id;
            self.table.put(self.allocator, self.next_id, bytes) catch return StoreError.Allocation;
            self.next_id += 1;

            return .{ .key = id, .bytes = bytes };
        }

        fn fetch(ptr: *anyopaque, id: usize) ?[]u8 {
            var self: *Self = @ptrCast(@alignCast(ptr));
            return self.table.get(id);
        }

        fn store(self: *Self) Store {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = Self.alloc,
                    .fetch = Self.fetch,
                },
            };
        }
    };
}

test "hashstore works" {
    const Foo = struct { baz: []const u8 };

    var hs: hash_store(Foo) = .init(std.testing.allocator);
    defer hs.deinit();
    var in_memory_store = hs.store();

    const kv = try in_memory_store.alloc();
    const id = kv.key;
    const bytes = kv.bytes;

    const foo: *Foo = @ptrCast(@alignCast(bytes));
    foo.* = .{ .baz = "bar" };
    const value = in_memory_store.fetch(id);

    try std.testing.expectEqualSlices(u8, value.?, bytes);
}
