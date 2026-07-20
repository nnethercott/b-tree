const std = @import("std");
const expect = std.testing.expect;

pub fn main() !void {
    const nums = [_]u8{ 1, 2, 3 };

    const S = struct {
        fn cmp(ctx: comptime_int, needle: u8) std.math.Order {
            return std.math.order(ctx, needle);
        }
    };

    const idx = std.sort.upperBound(u8, &nums, 4, S.cmp);
    try expect(idx == 3);
}
