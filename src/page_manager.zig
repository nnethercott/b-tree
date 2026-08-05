const std = @import("std");
const Io = std.Io;
const Store = @import("Store.zig");

// TODO:(roaring)
// - move the translate c step to build.zig
// - figure out how to serialize/deserialize the bitmap
// const roaring = @import("roaring.zig");

pub const PageManager = struct {
    io: std.Io,
    map: Io.File.MemoryMap,
    offset: usize = 0,
    page_size: usize,

    // in_use: *roaring.roaring_bitmap_t,

    const Self = @This();

    pub fn init(file_name: []const u8, io: Io, len: usize) !PageManager {
        // https://cookbook.ziglang.cc/01-02-mmap-file/
        const file = try std.Io.Dir.cwd().createFile(io, file_name, .{
            .read = true,
            .exclusive = false,
            .truncate = true,
        });
        errdefer file.close(io);
        try file.setLength(io, len);

        const map = try file.createMemoryMap(io, .{ .len = len });
        errdefer map.destroy(io);

        return .{
            .io = io,
            .map = map,
            .page_size = std.heap.pageSize(),
            // .in_use = roaring.roaring_bitmap_create(),
        };
    }

    fn getPage(self: *const Self, page_id: usize) []u8 {
        return self.map.memory[page_id * self.page_size .. (page_id + 1) * self.page_size];
    }

    fn remap(self: *Self, len: usize) !void {
        const file = self.map.file;
        self.map.destroy(self.io);
        try file.setLength(self.io, len);
        self.map = try file.createMemoryMap(self.io, .{ .len = len });
    }

    // FIXME: we need to raise the interface error. 
    // Let's look into how we can do this better !
    fn alloc(self: *Self) !Store.KV {
        // FIXME: should we err here or continue remapping ?
        if (self.offset * self.page_size >= self.map.memory.len) {
            try self.remap(2 * self.map.memory.len);
        }
        const id = self.offset;
        const kv: Store.KV = .{
            .key = id,
            .bytes = self.getPage(id),
        };
        self.offset += 1;

        return kv;
    }

    fn fetch(self: *Self, id: usize) ?[]u8 {
        if (id >= self.offset) {
            return null;
        }
        return self.getPage(id);
    }

    // Returns a file-backed implementation of the `Store` interface
    pub fn store(self: *Self) Store {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = Self.alloc,
                .fetch = Self.fetch,
            },
        };
    }
};
