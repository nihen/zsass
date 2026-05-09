const std = @import("std");

/// Family of a CSS unit (used by `comparableUnitInfoCi` for cross-unit math).
pub const UnitFamily = enum { length, angle, time, frequency, resolution };

/// Result of `comparableUnitInfoCi`. `factor` converts `1 unit` to canonical
/// (px / deg / s / Hz / dppx).
pub const ComparableUnitInfo = struct {
    family: UnitFamily,
    factor: f64,
};

/// Result of `canonicalComparableFactorCi`. `name` is the canonical unit
/// string for the family; `factor` is the scale to canonical.
pub const CanonicalComparableFactor = struct {
    name: []const u8,
    factor: f64,
};

pub fn unitsMatch(unit_a: ?[]const u8, unit_b: ?[]const u8) bool {
    if (unit_a == null and unit_b == null) return true;
    if (unit_a == null or unit_b == null) return false;
    return std.mem.eql(u8, unit_a.?, unit_b.?);
}

/// Case-insensitive lookup of family + canonical-conversion factor for
/// `unit`. Returns `null` for unknown / non-comparable units.
pub fn comparableUnitInfoCi(unit: []const u8) ?ComparableUnitInfo {
    // Length (canonical: px)
    if (std.ascii.eqlIgnoreCase(unit, "px")) return .{ .family = .length, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "in")) return .{ .family = .length, .factor = 96.0 };
    if (std.ascii.eqlIgnoreCase(unit, "cm")) return .{ .family = .length, .factor = 96.0 / 2.54 };
    if (std.ascii.eqlIgnoreCase(unit, "mm")) return .{ .family = .length, .factor = 96.0 / 25.4 };
    if (std.ascii.eqlIgnoreCase(unit, "pt")) return .{ .family = .length, .factor = 96.0 / 72.0 };
    if (std.ascii.eqlIgnoreCase(unit, "pc")) return .{ .family = .length, .factor = 16.0 };
    if (std.ascii.eqlIgnoreCase(unit, "q")) return .{ .family = .length, .factor = 96.0 / 101.6 };

    // Angle (canonical: deg)
    if (std.ascii.eqlIgnoreCase(unit, "deg")) return .{ .family = .angle, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "rad")) return .{ .family = .angle, .factor = 180.0 / std.math.pi };
    if (std.ascii.eqlIgnoreCase(unit, "grad")) return .{ .family = .angle, .factor = 0.9 };
    if (std.ascii.eqlIgnoreCase(unit, "turn")) return .{ .family = .angle, .factor = 360.0 };

    // Time (canonical: s)
    if (std.ascii.eqlIgnoreCase(unit, "s")) return .{ .family = .time, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "ms")) return .{ .family = .time, .factor = 0.001 };

    // Frequency (canonical: Hz)
    if (std.ascii.eqlIgnoreCase(unit, "hz")) return .{ .family = .frequency, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "khz")) return .{ .family = .frequency, .factor = 1000.0 };

    // Resolution (canonical: dppx)
    if (std.ascii.eqlIgnoreCase(unit, "dppx")) return .{ .family = .resolution, .factor = 1.0 };
    if (std.ascii.eqlIgnoreCase(unit, "dpi")) return .{ .family = .resolution, .factor = 1.0 / 96.0 };
    if (std.ascii.eqlIgnoreCase(unit, "dpcm")) return .{ .family = .resolution, .factor = 2.54 / 96.0 };
    return null;
}

/// Case-insensitive lookup that also reports the canonical unit string.
pub fn canonicalComparableFactorCi(unit: []const u8) ?CanonicalComparableFactor {
    const info = comparableUnitInfoCi(unit) orelse return null;
    const name: []const u8 = switch (info.family) {
        .length => "px",
        .angle => "deg",
        .time => "s",
        .frequency => "Hz",
        .resolution => "dppx",
    };
    return .{ .name = name, .factor = info.factor };
}

/// Case-insensitive `value * canonicalFactor(unit)`. `null` for unknown unit.
pub fn toComparableCanonicalCi(value: f64, unit: []const u8) ?f64 {
    const info = comparableUnitInfoCi(unit) orelse return null;
    return value * info.factor;
}

/// Case-insensitive cross-unit conversion. Returns `null` if either unit is
/// unknown or the two units belong to different families.
pub fn convertComparableUnitCi(value: f64, from: []const u8, to: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(from, to)) return value;
    const from_info = comparableUnitInfoCi(from) orelse return null;
    const to_info = comparableUnitInfoCi(to) orelse return null;
    if (from_info.family != to_info.family) return null;
    return value * from_info.factor / to_info.factor;
}
pub fn toCanonical(value: f64, unit: []const u8) ?f64 {
    // Length  ->  px
    if (std.mem.eql(u8, unit, "px")) return value;
    if (std.mem.eql(u8, unit, "in")) return value * 96.0;
    if (std.mem.eql(u8, unit, "cm")) return value * 96.0 / 2.54;
    if (std.mem.eql(u8, unit, "mm")) return value * 96.0 / 25.4;
    if (std.mem.eql(u8, unit, "pt")) return value * 96.0 / 72.0;
    if (std.mem.eql(u8, unit, "pc")) return value * 96.0 / 6.0;
    if (std.mem.eql(u8, unit, "Q") or std.mem.eql(u8, unit, "q")) return value * 96.0 / 101.6;
    // Angle  ->  you
    if (std.mem.eql(u8, unit, "deg")) return value;
    if (std.mem.eql(u8, unit, "rad")) return value * 180.0 / std.math.pi;
    if (std.mem.eql(u8, unit, "grad")) return value * 0.9;
    if (std.mem.eql(u8, unit, "turn")) return value * 360.0;
    // Time  ->  s
    if (std.mem.eql(u8, unit, "s")) return value;
    if (std.mem.eql(u8, unit, "ms")) return value / 1000.0;
    // Frequency  ->  Hz
    if (std.mem.eql(u8, unit, "Hz")) return value;
    if (std.mem.eql(u8, unit, "kHz")) return value * 1000.0;
    // Resolution  ->  dppx
    if (std.mem.eql(u8, unit, "dppx")) return value;
    if (std.mem.eql(u8, unit, "dpi")) return value / 96.0;
    if (std.mem.eql(u8, unit, "dpcm")) return value * 2.54 / 96.0;
    return null;
}

pub fn fromCanonical(value: f64, unit: []const u8) ?f64 {
    // Length: canonical = px
    if (std.mem.eql(u8, unit, "px")) return value;
    if (std.mem.eql(u8, unit, "in")) return value / 96.0;
    if (std.mem.eql(u8, unit, "cm")) return value * 2.54 / 96.0;
    if (std.mem.eql(u8, unit, "mm")) return value * 25.4 / 96.0;
    if (std.mem.eql(u8, unit, "pt")) return value * 72.0 / 96.0;
    if (std.mem.eql(u8, unit, "pc")) return value * 6.0 / 96.0;
    if (std.mem.eql(u8, unit, "Q") or std.mem.eql(u8, unit, "q")) return value * 101.6 / 96.0;
    // Angle: canonical = deg
    if (std.mem.eql(u8, unit, "deg")) return value;
    if (std.mem.eql(u8, unit, "rad")) return value * std.math.pi / 180.0;
    if (std.mem.eql(u8, unit, "grad")) return value / 0.9;
    if (std.mem.eql(u8, unit, "turn")) return value / 360.0;
    // Time: canonical = s
    if (std.mem.eql(u8, unit, "s")) return value;
    if (std.mem.eql(u8, unit, "ms")) return value * 1000.0;
    // Frequency: canonical = Hz
    if (std.mem.eql(u8, unit, "Hz")) return value;
    if (std.mem.eql(u8, unit, "kHz")) return value / 1000.0;
    // Resolution: canonical = dppx
    if (std.mem.eql(u8, unit, "dppx")) return value;
    if (std.mem.eql(u8, unit, "dpi")) return value * 96.0;
    if (std.mem.eql(u8, unit, "dpcm")) return value * 96.0 / 2.54;
    return null;
}
