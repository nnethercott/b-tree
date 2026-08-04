const roaring = @import("roaring.zig");

pub const PageManager = struct {
    in_use: *roaring.roaring_bitmap_t,

    pub fn init() PageManager {
        return .{ .in_use = roaring.roaring_bitmap_create() };
    }
};
