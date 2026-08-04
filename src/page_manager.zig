const std = @import("std");
const Io = std.Io;

// TODO:(roaring)
// - move the translate c step to build.zig
// - figure out how to serialize/deserialize the bitmap
// const roaring = @import("roaring.zig");

pub const PageManager = struct {
    map: Io.File.MemoryMap,
    io: std.Io,
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

    fn remap(self: *Self, len: usize) !void {
        const file = self.map.file;
        self.map.destroy(self.io);
        try file.setLength(self.io, len);
        self.map = try file.createMemoryMap(self.io, .{ .len = len });
    }

    fn getPage(self: *const Self, page_id: usize) []u8 {
        return self.map.memory[page_id * self.page_size .. (page_id + 1) * self.page_size];
    }

    pub fn nextPage(self: *Self) ![]u8 {
        if (self.offset * self.page_size >= self.map.memory.len) {
            try self.remap(2 * self.map.memory.len);
        }

        const slice = self.getPage(self.offset);
        self.offset += 1;

        return slice;
    }
};
