//! Converting a Sass number to an integer without leaving the range of the
//! integer type, which `@intFromFloat` does not check in release builds.

const std = @import("std");

const two_pow_63: f64 = 0x1p63;

/// The 64-bit integer an integral `x` reads as, the way the official CLI
/// reads one: the conversion saturates, and `x` counts as that integer when
/// the integer converts back to `x`. So 2^63 reads as the largest 64-bit
/// integer, while 2^64 is no integer at all. Null for anything not finite or
/// outside that range. A fractional `x` is truncated.
pub fn toI64(x: f64) ?i64 {
    if (!std.math.isFinite(x)) return null;
    if (x >= two_pow_63) return if (x == two_pow_63) std.math.maxInt(i64) else null;
    if (x < -two_pow_63) return null;
    return @intFromFloat(x);
}

test "toI64 saturates at the ends of the 64-bit range and refuses beyond" {
    try std.testing.expectEqual(@as(?i64, 3), toI64(3));
    try std.testing.expectEqual(@as(?i64, -3), toI64(-3.7));
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i64)), toI64(0x1p63));
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i64)), toI64(-0x1p63));
    try std.testing.expectEqual(@as(?i64, null), toI64(0x1p64));
    try std.testing.expectEqual(@as(?i64, null), toI64(-0x1p64));
    try std.testing.expectEqual(@as(?i64, null), toI64(1e300));
    try std.testing.expectEqual(@as(?i64, null), toI64(std.math.inf(f64)));
    try std.testing.expectEqual(@as(?i64, null), toI64(std.math.nan(f64)));
}
