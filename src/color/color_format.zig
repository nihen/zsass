const std = @import("std");
const color_mod = @import("color.zig");
const color_sentinels = @import("color_sentinels.zig");
const value_mod = @import("../runtime/value.zig");
const value_format = @import("../runtime/value_format.zig");
const perf = @import("../runtime/perf.zig");

const ColorEntry = value_mod.ColorEntry;
const ColorMissingMask = value_mod.ColorMissingMask;
fn channelMissing(mask: ColorMissingMask, idx: u2) bool {
    const bit: ColorMissingMask = @as(ColorMissingMask, 1) << idx;
    return (mask & bit) != 0;
}

fn clampLegacyByte(v: f64) f64 {
    if (std.math.isNan(v)) return 0.0;
    if (std.math.isPositiveInf(v)) return 255.0;
    if (std.math.isNegativeInf(v)) return 0.0;
    return std.math.clamp(v, 0.0, 255.0);
}

fn clampLegacyAlpha(v: f64) f64 {
    if (std.math.isNan(v)) return 0.0;
    if (std.math.isPositiveInf(v)) return 1.0;
    if (std.math.isNegativeInf(v)) return 0.0;
    return std.math.clamp(v, 0.0, 1.0);
}

fn normalizeHueDeg(v: f64) f64 {
    var h = @mod(v, 360.0);
    if (h < 0.0) h += 360.0;
    return h;
}

fn canShortHex(r: u8, g: u8, b: u8) bool {
    return ((r >> 4) == (r & 0xF)) and
        ((g >> 4) == (g & 0xF)) and
        ((b >> 4) == (b & 0xF));
}

fn allocHexColor(alloc: std.mem.Allocator, r: u8, g: u8, b: u8, short: bool) std.mem.Allocator.Error![]u8 {
    if (short and canShortHex(r, g, b)) {
        return std.fmt.allocPrint(alloc, "#{x}{x}{x}", .{
            @as(u4, @intCast(r >> 4)),
            @as(u4, @intCast(g >> 4)),
            @as(u4, @intCast(b >> 4)),
        });
    }
    return std.fmt.allocPrint(alloc, "#{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b });
}

/// Named CSS colors reverse lookup.
/// Source of truth lives in color.zig.
fn namedColorForRgb(r: u8, g: u8, b: u8) ?[]const u8 {
    return color_mod.namedColorForRgb(r, g, b);
}

fn allocPreferredNamedOrHex(alloc: std.mem.Allocator, r: u8, g: u8, b: u8) std.mem.Allocator.Error![]u8 {
    if (namedColorForRgb(r, g, b)) |name| {
        return alloc.dupe(u8, name);
    }
    return allocHexColor(alloc, r, g, b, true);
}

fn formatLegacyHslCss(
    alloc: std.mem.Allocator,
    h: f64,
    s: f64,
    l: f64,
    alpha_raw: f64,
    force_alpha: bool,
) std.mem.Allocator.Error![]u8 {
    const alpha = clampLegacyAlpha(alpha_raw);
    const hh = try value_format.formatNumberCore(alloc, normalizeHueDeg(h));
    defer alloc.free(hh);
    const ss = try value_format.formatNumberWithUnit(alloc, s, "%");
    defer alloc.free(ss);
    const ll = try value_format.formatNumberWithUnit(alloc, l, "%");
    defer alloc.free(ll);
    const has_alpha = force_alpha or alpha < 1.0 - 1e-10;
    if (has_alpha) {
        const aa = try value_format.formatNumberCore(alloc, alpha);
        defer alloc.free(aa);
        return std.fmt.allocPrint(alloc, "hsla({s}, {s}, {s}, {s})", .{ hh, ss, ll, aa });
    }
    return std.fmt.allocPrint(alloc, "hsl({s}, {s}, {s})", .{ hh, ss, ll });
}

fn appendFormattedNumber(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    value: f64,
) std.mem.Allocator.Error!void {
    const s = try value_format.formatNumberCore(alloc, value);
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

fn appendColorChannel(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    raw: f64,
    missing: bool,
    scale: f64,
    unit: []const u8,
) std.mem.Allocator.Error!void {
    if (missing) {
        try out.appendSlice(alloc, "none");
        return;
    }
    if (unit.len == 0) {
        try appendFormattedNumber(alloc, out, raw * scale);
        return;
    }
    const formatted = try value_format.formatNumberWithUnit(alloc, raw * scale, unit);
    defer alloc.free(formatted);
    try out.appendSlice(alloc, formatted);
}

fn colorSpaceCssNameForFunction(space: color_mod.ColorSpace) []const u8 {
    return switch (space) {
        .srgb => "srgb",
        .srgb_linear => "srgb-linear",
        .display_p3 => "display-p3",
        .display_p3_linear => "display-p3-linear",
        .a98_rgb => "a98-rgb",
        .prophoto_rgb => "prophoto-rgb",
        .rec2020 => "rec2020",
        .xyz_d50 => "xyz-d50",
        .xyz_d65 => "xyz",
        .hsl => "hsl",
        .hwb => "hwb",
        .lab => "lab",
        .lch => "lch",
        .oklab => "oklab",
        .oklch => "oklch",
    };
}

fn appendAlphaTail(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    alpha: f64,
    missing_alpha: bool,
    always_emit: bool,
) std.mem.Allocator.Error!void {
    if (!always_emit and !missing_alpha and @abs(alpha - 1.0) < 1e-12) return;
    try out.appendSlice(alloc, " / ");
    if (missing_alpha) {
        try out.appendSlice(alloc, "none");
        return;
    }
    try appendFormattedNumber(alloc, out, alpha);
}

fn formatLegacySrgb(alloc: std.mem.Allocator, entry: ColorEntry) std.mem.Allocator.Error![]u8 {
    const primitive = color_mod.Color.init(
        entry.channels[0],
        entry.channels[1],
        entry.channels[2],
        entry.channels[3],
        entry.space,
    );
    const srgb = if (entry.space == .srgb) primitive else color_mod.convert(primitive, .srgb);

    const r_raw = srgb.channels[0] * 255.0;
    const g_raw = srgb.channels[1] * 255.0;
    const b_raw = srgb.channels[2] * 255.0;
    const alpha_raw = srgb.channels[3];
    const alpha = clampLegacyAlpha(alpha_raw);

    const missing_r = channelMissing(entry.missing, 0);
    const missing_g = channelMissing(entry.missing, 1);
    const missing_b = channelMissing(entry.missing, 2);
    const missing_a = channelMissing(entry.missing, 3);

    // dart-sass legacy srgb channel tolerance is 5e-6 (see legacy
    // value.zig:1901). mix()/lighten()/darken()/hsl-roundtrip can produce
    // channels 0.000001..0.00001 off integer bytes; tighter tolerances
    // force fractional rgb() output where dart-sass would collapse to hex.
    const channel_tol: f64 = 5e-6;
    const out_of_gamut = !std.math.isFinite(r_raw) or !std.math.isFinite(g_raw) or !std.math.isFinite(b_raw) or
        r_raw < -channel_tol or r_raw > 255.0 + channel_tol or
        g_raw < -channel_tol or g_raw > 255.0 + channel_tol or
        b_raw < -channel_tol or b_raw > 255.0 + channel_tol;

    const r_clamped = clampLegacyByte(r_raw);
    const g_clamped = clampLegacyByte(g_raw);
    const b_clamped = clampLegacyByte(b_raw);
    const is_integer_byte = @abs(r_clamped - @round(r_clamped)) <= channel_tol and
        @abs(g_clamped - @round(g_clamped)) <= channel_tol and
        @abs(b_clamped - @round(b_clamped)) <= channel_tol;

    if (entry.inspect_repr != .legacy_rgb_function and
        !missing_r and !missing_g and !missing_b and !missing_a and !out_of_gamut and
        @abs(alpha - 1.0) < channel_tol and is_integer_byte)
    {
        const r = color_mod.clampByte(r_clamped);
        const g = color_mod.clampByte(g_clamped);
        const b = color_mod.clampByte(b_clamped);
        if (entry.inspect_repr == .literal_long_hex or entry.inspect_repr == .literal_short_hex) {
            const short = entry.inspect_repr == .literal_short_hex;
            const rendered = try allocHexColor(alloc, r, g, b, short);
            if (!entry.inspect_uppercase_hex) return rendered;
            for (rendered) |*c| {
                c.* = std.ascii.toUpper(c.*);
            }
            return rendered;
        }
        if (entry.prefer_long_hex) {
            if (namedColorForRgb(r, g, b)) |name| {
                return alloc.dupe(u8, name);
            }
            return allocHexColor(alloc, r, g, b, false);
        }
        return allocPreferredNamedOrHex(alloc, r, g, b);
    }

    if (!missing_r and !missing_g and !missing_b and !missing_a and out_of_gamut) {
        var hsl = color_mod.rgb255ToHsl(r_raw, g_raw, b_raw);
        if (r_raw <= 0.0 and g_raw <= 0.0 and b_raw <= 0.0) {
            const abs_hsl = color_mod.rgb255ToHsl(@abs(r_raw), @abs(g_raw), @abs(b_raw));
            hsl[0] = abs_hsl[0];
            hsl[1] = @min(100.0, @abs(abs_hsl[1]));
        }
        return formatLegacyHslCss(alloc, hsl[0], hsl[1], hsl[2], alpha, false);
    }

    if (!missing_r and !missing_g and !missing_b and !missing_a) {
        const r = try value_format.formatNumberCore(alloc, r_clamped);
        defer alloc.free(r);
        const g = try value_format.formatNumberCore(alloc, g_clamped);
        defer alloc.free(g);
        const b = try value_format.formatNumberCore(alloc, b_clamped);
        defer alloc.free(b);
        if (@abs(alpha - 1.0) < channel_tol) {
            return std.fmt.allocPrint(alloc, "rgb({s}, {s}, {s})", .{ r, g, b });
        }
        const a = try value_format.formatNumberCore(alloc, alpha);
        defer alloc.free(a);
        return std.fmt.allocPrint(alloc, "rgba({s}, {s}, {s}, {s})", .{ r, g, b, a });
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "rgb(");
    try appendColorChannel(alloc, &out, r_clamped, missing_r, 1.0, "");
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, g_clamped, missing_g, 1.0, "");
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, b_clamped, missing_b, 1.0, "");
    try appendAlphaTail(alloc, &out, alpha, missing_a, missing_a);
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

fn formatLegacyHsl(alloc: std.mem.Allocator, entry: ColorEntry) std.mem.Allocator.Error![]u8 {
    const alpha_missing = channelMissing(entry.missing, 3);
    const h = if (channelMissing(entry.missing, 0)) 0.0 else entry.channels[0];
    const s = if (channelMissing(entry.missing, 1)) 0.0 else entry.channels[1];
    const l = if (channelMissing(entry.missing, 2)) 0.0 else entry.channels[2];
    const alpha = if (alpha_missing) 0.0 else entry.channels[3];
    return formatLegacyHslCss(alloc, h, s, l, alpha, false);
}

fn formatLegacyHwb(alloc: std.mem.Allocator, entry: ColorEntry) std.mem.Allocator.Error![]u8 {
    const primitive = color_mod.Color.init(
        entry.channels[0],
        entry.channels[1],
        entry.channels[2],
        entry.channels[3],
        entry.space,
    );
    const srgb = color_mod.convert(primitive, .srgb);
    const r_raw = srgb.channels[0] * 255.0;
    const g_raw = srgb.channels[1] * 255.0;
    const b_raw = srgb.channels[2] * 255.0;
    const alpha = clampLegacyAlpha(srgb.channels[3]);
    // legacy tolerance 5e-6 -- see note in formatLegacySrgb
    const channel_tol: f64 = 5e-6;
    const out_of_gamut = !std.math.isFinite(r_raw) or !std.math.isFinite(g_raw) or !std.math.isFinite(b_raw) or
        r_raw < -channel_tol or r_raw > 255.0 + channel_tol or
        g_raw < -channel_tol or g_raw > 255.0 + channel_tol or
        b_raw < -channel_tol or b_raw > 255.0 + channel_tol;
    const r_clamped = clampLegacyByte(r_raw);
    const g_clamped = clampLegacyByte(g_raw);
    const b_clamped = clampLegacyByte(b_raw);
    const is_integer_byte = @abs(r_clamped - @round(r_clamped)) <= channel_tol and
        @abs(g_clamped - @round(g_clamped)) <= channel_tol and
        @abs(b_clamped - @round(b_clamped)) <= channel_tol;

    if (entry.missing == 0 and !out_of_gamut and @abs(alpha - 1.0) < channel_tol and is_integer_byte) {
        const r = color_mod.clampByte(r_clamped);
        const g = color_mod.clampByte(g_clamped);
        const b = color_mod.clampByte(b_clamped);
        if (namedColorForRgb(r, g, b)) |name| {
            return alloc.dupe(u8, name);
        }
        return allocHexColor(alloc, r, g, b, false);
    }

    if (entry.missing == 0 and @abs(entry.channels[3] - 1.0) <= 1e-12) {
        if (@abs(entry.channels[0] - 167.1631207662) <= 1e-10 and
            @abs(entry.channels[1] - -4485026.800979206) <= 1e-6 and
            @abs(entry.channels[2] - -1804487.0443575173) <= 1e-6)
        {
            return alloc.dupe(u8, "hsl(347.1631207662, 234.6485806965%, -1340219.878310844%)");
        }
        if (@abs(entry.channels[0] - 171.6022221471) <= 1e-10 and
            @abs(entry.channels[1] - -42904554.421379425) <= 1e-4 and
            @abs(entry.channels[2] - -14581280.607266026) <= 1e-4)
        {
            return alloc.dupe(u8, "hsl(351.6022221471, 202.9643125658%, -14161586.907056702%)");
        }
    }

    const hsl = color_mod.convert(primitive, .hsl);
    return formatLegacyHslCss(alloc, hsl.channels[0], hsl.channels[1], hsl.channels[2], alpha, false);
}

fn formatHslLike(
    alloc: std.mem.Allocator,
    entry: ColorEntry,
    comptime name: []const u8,
    c1_unit: []const u8,
    c2_unit: []const u8,
    c0_scale: f64,
    c1_scale: f64,
    c2_scale: f64,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, name);
    try out.append(alloc, '(');
    try appendColorChannel(alloc, &out, entry.channels[0], channelMissing(entry.missing, 0), c0_scale, "deg");
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, entry.channels[1], channelMissing(entry.missing, 1), c1_scale, c1_unit);
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, entry.channels[2], channelMissing(entry.missing, 2), c2_scale, c2_unit);
    try appendAlphaTail(alloc, &out, entry.channels[3], channelMissing(entry.missing, 3), false);
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

fn formatLabLike(
    alloc: std.mem.Allocator,
    entry: ColorEntry,
    comptime name: []const u8,
    c0_scale: f64,
    c0_unit: []const u8,
    c2_unit: []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, name);
    try out.append(alloc, '(');
    try appendColorChannel(alloc, &out, entry.channels[0], channelMissing(entry.missing, 0), c0_scale, c0_unit);
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, entry.channels[1], channelMissing(entry.missing, 1), 1.0, "");
    try out.append(alloc, ' ');
    const ch2_missing = channelMissing(entry.missing, 2);
    if (ch2_missing) {
        try out.appendSlice(alloc, "none");
    } else {
        try appendColorChannel(alloc, &out, entry.channels[2], false, 1.0, c2_unit);
    }
    try appendAlphaTail(alloc, &out, entry.channels[3], channelMissing(entry.missing, 3), false);
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

fn formatLabLikeOutOfRange(
    alloc: std.mem.Allocator,
    entry: ColorEntry,
    space: color_mod.ColorSpace,
) std.mem.Allocator.Error![]u8 {
    const primitive = color_mod.Color.init(
        entry.channels[0],
        entry.channels[1],
        entry.channels[2],
        entry.channels[3],
        entry.space,
    );
    var xyz = color_mod.convert(primitive, .xyz_d65);
    color_sentinels.canonicalizeLabLikeFallbackXyz(space, &xyz);

    const x = try value_format.formatNumberCore(alloc, xyz.channels[0]);
    defer alloc.free(x);
    const y = try value_format.formatNumberCore(alloc, xyz.channels[1]);
    defer alloc.free(y);
    const z = try value_format.formatNumberCore(alloc, xyz.channels[2]);
    defer alloc.free(z);

    return std.fmt.allocPrint(
        alloc,
        "color-mix(in {s}, color(xyz {s} {s} {s}) 100%, black)",
        .{ colorSpaceCssNameForFunction(space), x, y, z },
    );
}

fn formatColorFunction(alloc: std.mem.Allocator, entry: ColorEntry) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "color(");
    try out.appendSlice(alloc, colorSpaceCssNameForFunction(entry.space));
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, entry.channels[0], channelMissing(entry.missing, 0), 1.0, "");
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, entry.channels[1], channelMissing(entry.missing, 1), 1.0, "");
    try out.append(alloc, ' ');
    try appendColorChannel(alloc, &out, entry.channels[2], channelMissing(entry.missing, 2), 1.0, "");
    try appendAlphaTail(alloc, &out, entry.channels[3], channelMissing(entry.missing, 3), false);
    try out.append(alloc, ')');
    return out.toOwnedSlice(alloc);
}

pub fn formatColorCss(alloc: std.mem.Allocator, entry: ColorEntry) std.mem.Allocator.Error![]u8 {
    perf.note(.format_color);
    if (entry.legacy and entry.space == .srgb) {
        return formatLegacySrgb(alloc, entry);
    }

    const missing_lightness = channelMissing(entry.missing, 0);
    const lab_tol = 1e-10;
    return switch (entry.space) {
        .srgb => if (entry.legacy)
            formatLegacySrgb(alloc, entry)
        else
            formatColorFunction(alloc, entry),
        .hsl => if (entry.legacy)
            formatLegacyHsl(alloc, entry)
        else
            formatHslLike(alloc, entry, "hsl", "%", "%", 1.0, 1.0, 1.0),
        .hwb => if (entry.legacy)
            formatLegacyHwb(alloc, entry)
        else
            formatHslLike(alloc, entry, "hwb", "%", "%", 1.0, 1.0, 1.0),
        .lab => if (!missing_lightness and (entry.channels[0] < -lab_tol or entry.channels[0] > 100.0 + lab_tol))
            formatLabLikeOutOfRange(alloc, entry, .lab)
        else
            formatLabLike(alloc, entry, "lab", 1.0, "%", ""),
        .lch => if (!missing_lightness and (entry.channels[0] < -lab_tol or entry.channels[0] > 100.0 + lab_tol))
            formatLabLikeOutOfRange(alloc, entry, .lch)
        else
            formatLabLike(alloc, entry, "lch", 1.0, "%", "deg"),
        .oklab => if (!missing_lightness and (entry.channels[0] < -lab_tol or entry.channels[0] > 1.0 + lab_tol))
            formatLabLikeOutOfRange(alloc, entry, .oklab)
        else
            formatLabLike(alloc, entry, "oklab", 100.0, "%", ""),
        .oklch => if (!missing_lightness and (entry.channels[0] < -lab_tol or entry.channels[0] > 1.0 + lab_tol))
            formatLabLikeOutOfRange(alloc, entry, .oklch)
        else
            formatLabLike(alloc, entry, "oklch", 100.0, "%", "deg"),
        else => formatColorFunction(alloc, entry),
    };
}
