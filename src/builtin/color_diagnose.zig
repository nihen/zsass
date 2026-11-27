//! Explains why a color constructor (`rgb()`, `hsl()`, `hwb()`, `lab()`,
//! `lch()`, `oklab()`, `oklch()`, `color()`) rejected its arguments, with
//! the messages the official CLI reports. It runs only once a constructor
//! has failed without saying why, so it never changes what succeeds.

const std = @import("std");
const shared = @import("shared.zig");
const color_mod = @import("../color/color.zig");
const error_format = @import("../runtime/error_format.zig");
const value_format = @import("../runtime/value_format.zig");

const Value = shared.Value;
const InternId = shared.InternId;
const BuiltinContext = shared.BuiltinContext;

pub const Constructor = enum { rgb, hsl, hwb, lab, lch, oklab, oklch, color };

/// Sets the message for a constructor call that failed; leaves it unset
/// when no rule here explains the failure.
pub fn explain(ctx: *BuiltinContext, ctor: Constructor, args: []const Value, arg_names: []const InternId) void {
    explainInner(ctx, ctor, args, arg_names) catch {};
}

const Explained = error{Explained};

fn explainInner(ctx: *BuiltinContext, ctor: Constructor, args: []const Value, arg_names: []const InternId) (Explained || shared.BuiltinError)!void {
    for (arg_names) |name| {
        // Spread arguments are bound by the constructor itself.
        if (@backingInt(name) == std.math.maxInt(u32)) return;
    }
    const one_arg_name: []const u8 = if (ctor == .color) "description" else "channels";
    if (args.len == 1) {
        if (arg_names.len > 0 and arg_names[0] != .none and !shared.argNameMatches(ctx, arg_names[0], one_arg_name)) return;
        return explainChannels(ctx, ctor, args[0], one_arg_name);
    }
    if (ctor == .rgb and args.len == 2) return explainColorAndAlpha(ctx, args);
    // Two arguments fit neither form: hsl() is missing its lightness, and
    // hwb() takes its channels as one argument.
    if (ctor == .hsl and args.len == 2) return fail(ctx, "Missing argument $lightness.", .{});
    if (ctor == .hwb and args.len == 2) return fail(ctx, "Only 1 argument allowed, but 2 were passed.", .{});
    if (args.len >= 3 and args.len <= 4 and (ctor == .rgb or ctor == .hsl or ctor == .hwb)) {
        for (arg_names) |name| {
            if (name != .none) return;
        }
        const names = channelNames(ctor);
        for (args[0..3], 0..) |arg, i| {
            if (isChannelValue(ctx, arg)) continue;
            // hwb()'s channels are named after the channels, not the
            // arguments.
            if (ctor == .hwb) return fail(ctx, "Expected {s} channel to be a number, was {s}.", .{ names[i], try inspect(ctx, arg) });
            return fail(ctx, "${s}: {s} is not a number.", .{ names[i], try inspect(ctx, arg) });
        }
        for (args[0..3], 0..) |arg, i| try checkChannelUnit(ctx, ctor, i, arg);
        if (args.len == 4) try checkAlpha(ctx, args[3], "alpha");
    }
}

fn explainColorAndAlpha(ctx: *BuiltinContext, args: []const Value) (Explained || shared.BuiltinError)!void {
    const c = args[0];
    const is_color = c.kind() == .color or (c.isString() and !c.stringQuoted(ctx.string_flags_pool.items) and
        color_mod.lookupNamedColor(ctx.intern_pool.get(c.stringIntern())) != null);
    if (!is_color and !isSpecial(ctx, c)) return fail(ctx, "$color: {s} is not a color.", .{try inspect(ctx, c)});
    try checkAlpha(ctx, args[1], "alpha");
}

fn explainChannels(ctx: *BuiltinContext, ctor: Constructor, value: Value, param: []const u8) (Explained || shared.BuiltinError)!void {
    if (isSpecial(ctx, value)) return;
    const meta = ctx.list_meta_pool.items;
    var components = value;
    var alpha: ?Value = null;
    if (value.kind() == .list) {
        if (value.listBracketed(meta)) return fail(ctx, "${s}: Expected an unbracketed list, was {s}", .{ param, try inspect(ctx, value) });
        const items = ctx.list_pool.items[value.listHandle()];
        if (value.listComma(meta) and items.len > 1) return fail(ctx, "${s}: Expected a space- or slash-separated list, was {s}", .{ param, try listText(ctx, value) });
        if (value.listSlash(meta)) {
            if (items.len != 2) {
                const verb = if (items.len == 1) "was" else "were";
                return fail(ctx, "${s}: Only 2 slash-separated elements allowed, but {d} {s} passed.", .{ param, items.len, verb });
            }
            components = items[0];
            alpha = items[1];
            if (components.kind() == .list) {
                if (components.listBracketed(meta)) return fail(ctx, "${s}: Expected an unbracketed list, was {s}", .{ param, try inspect(ctx, components) });
                const parts = ctx.list_pool.items[components.listHandle()];
                if (components.listComma(meta) and parts.len > 1) return fail(ctx, "${s}: Expected a space-separated list, was {s}", .{ param, try listText(ctx, components) });
            }
        }
    }
    var channels_buf: [8]Value = undefined;
    var channels: []const Value = blk: {
        if (components.kind() == .list) {
            const parts = ctx.list_pool.items[components.listHandle()];
            break :blk parts;
        }
        channels_buf[0] = components;
        break :blk channels_buf[0..1];
    };
    if (channels.len == 0) return fail(ctx, "${s}: Color component list may not be empty.", .{param});

    var space_name: []const u8 = @tagName(ctor);
    var space_ctor = ctor;
    if (ctor == .color) {
        const head = channels[0];
        if (!head.isString()) return fail(ctx, "${s}: {s} is not a string.", .{ param, try inspect(ctx, head) });
        const name = ctx.intern_pool.get(head.stringIntern());
        if (head.stringQuoted(ctx.string_flags_pool.items)) return fail(ctx, "${s}: Expected \"{s}\" to be an unquoted string.", .{ param, name });
        if (!isPredefinedSpace(name)) return fail(ctx, "${s}: Unknown color space \"{s}\".", .{ param, name });
        space_name = name;
        space_ctor = if (std.mem.startsWith(u8, name, "xyz")) .color else .rgb;
        channels = channels[1..];
    }

    // The alpha may be written after a slash in the last channel.
    if (alpha == null and channels.len > 0) {
        const last = channels[channels.len - 1];
        if (last.kind() == .list and last.listSlash(meta) and !last.listBracketed(meta)) {
            const tail = ctx.list_pool.items[last.listHandle()];
            if (tail.len == 2 and channels.len <= channels_buf.len) {
                @memcpy(channels_buf[0..channels.len], channels);
                channels_buf[channels.len - 1] = tail[0];
                channels = channels_buf[0..channels.len];
                alpha = tail[1];
            }
        }
    }

    const names = channelNames(space_ctor);
    for (channels[0..@min(channels.len, 3)], 0..) |channel, i| {
        if (!isChannelValue(ctx, channel)) {
            return fail(ctx, "${s}: Expected {s} channel to be a number, was {s}.", .{ param, names[i], try inspect(ctx, channel) });
        }
    }
    if (channels.len != 3) {
        return fail(ctx, "${s}: The {s} color space has 3 channels but {s} has {d}.", .{ param, space_name, try listText(ctx, value), channels.len });
    }
    if (alpha) |a| {
        if (!isChannelValue(ctx, a)) return fail(ctx, "${s}: {s} is not a number.", .{ param, try inspect(ctx, a) });
    }
    for (channels, 0..) |channel, i| try checkChannelUnit(ctx, space_ctor, i, channel);
    if (alpha) |a| try checkAlpha(ctx, a, "alpha");
}

fn checkChannelUnit(ctx: *BuiltinContext, ctor: Constructor, index: usize, channel: Value) (Explained || shared.BuiltinError)!void {
    if (channel.kind() != .number) return;
    const unit_id = channel.unitId(ctx.number_pool);
    const unit: ?[]const u8 = if (unit_id == .none) null else ctx.intern_pool.get(unit_id);
    const name = channelNames(ctor)[index];
    const is_hue = (index == 0 and (ctor == .hsl or ctor == .hwb)) or (index == 2 and (ctor == .lch or ctor == .oklch));
    if (is_hue) {
        if (unit) |u| {
            if (!isAngleUnit(u)) return fail(ctx, "${s}: Expected {s} to have an angle unit (deg, grad, rad, turn).", .{ name, try numberText(ctx, channel) });
        }
        return;
    }
    if (ctor == .hwb) {
        if (unit == null or !std.mem.eql(u8, unit.?, "%")) return fail(ctx, "${s}: Expected {s} to have unit \"%\".", .{ name, try numberText(ctx, channel) });
        return;
    }
    if (ctor == .hsl) return;
    if (unit) |u| {
        if (!std.mem.eql(u8, u, "%")) return fail(ctx, "${s}: Expected {s} to have unit \"%\" or no units.", .{ name, try numberText(ctx, channel) });
    }
}

fn checkAlpha(ctx: *BuiltinContext, alpha: Value, param: []const u8) (Explained || shared.BuiltinError)!void {
    if (alpha.kind() != .number) {
        if (isChannelValue(ctx, alpha)) return;
        return fail(ctx, "${s}: {s} is not a number.", .{ param, try inspect(ctx, alpha) });
    }
    const unit_id = alpha.unitId(ctx.number_pool);
    if (unit_id == .none) return;
    if (!std.mem.eql(u8, ctx.intern_pool.get(unit_id), "%")) {
        return fail(ctx, "${s}: Expected {s} to have unit \"%\" or no units.", .{ param, try numberText(ctx, alpha) });
    }
}

fn channelNames(ctor: Constructor) [3][]const u8 {
    return switch (ctor) {
        .rgb => .{ "red", "green", "blue" },
        .hsl => .{ "hue", "saturation", "lightness" },
        .hwb => .{ "hue", "whiteness", "blackness" },
        .lab, .oklab => .{ "lightness", "a", "b" },
        .lch, .oklch => .{ "lightness", "chroma", "hue" },
        .color => .{ "x", "y", "z" },
    };
}

fn isPredefinedSpace(name: []const u8) bool {
    const spaces = [_][]const u8{ "srgb", "srgb-linear", "display-p3", "display-p3-linear", "a98-rgb", "prophoto-rgb", "rec2020", "xyz", "xyz-d50", "xyz-d65" };
    for (spaces) |s| {
        if (std.ascii.eqlIgnoreCase(name, s)) return true;
    }
    return false;
}

fn isAngleUnit(unit: []const u8) bool {
    return std.ascii.eqlIgnoreCase(unit, "deg") or std.ascii.eqlIgnoreCase(unit, "grad") or
        std.ascii.eqlIgnoreCase(unit, "rad") or std.ascii.eqlIgnoreCase(unit, "turn");
}

/// A number, `none`, or a special CSS function a channel may hold.
fn isChannelValue(ctx: *BuiltinContext, v: Value) bool {
    if (v.kind() == .number) return true;
    if (v.kind() == .calc_fragment or v.kind() == .interp_fragment) return true;
    if (!v.isString() or v.stringQuoted(ctx.string_flags_pool.items)) return false;
    const text = ctx.intern_pool.get(v.stringIntern());
    if (std.ascii.eqlIgnoreCase(text, "none")) return true;
    return isSpecialText(text);
}

fn isSpecial(ctx: *BuiltinContext, v: Value) bool {
    if (v.kind() == .calc_fragment or v.kind() == .interp_fragment) return true;
    if (!v.isString() or v.stringQuoted(ctx.string_flags_pool.items)) return false;
    return isSpecialText(ctx.intern_pool.get(v.stringIntern()));
}

fn isSpecialText(text: []const u8) bool {
    const t = std.mem.trimStart(u8, shared.stripCalcArgMarker(text), " \t\r\n");
    const prefixes = [_][]const u8{ "var(", "calc(", "env(", "attr(", "clamp(", "min(", "max(", "if(" };
    for (prefixes) |p| {
        if (std.ascii.startsWithIgnoreCase(t, p)) return true;
    }
    return false;
}

fn inspect(ctx: *BuiltinContext, v: Value) shared.BuiltinError![]const u8 {
    return shared.valueToInspectionString(ctx, v);
}

/// A list of two or more as the messages show it, in parentheses unless
/// bracketed.
fn listText(ctx: *BuiltinContext, v: Value) shared.BuiltinError![]const u8 {
    const text = try inspect(ctx, v);
    if (v.kind() != .list or v.listBracketed(ctx.list_meta_pool.items)) return text;
    if (ctx.list_pool.items[v.listHandle()].len < 2) return text;
    if (text.len > 0 and text[0] == '(') return text;
    defer ctx.allocator.free(text);
    return std.fmt.allocPrint(ctx.allocator, "({s})", .{text}) catch error.OutOfMemory;
}

fn numberText(ctx: *BuiltinContext, v: Value) shared.BuiltinError![]const u8 {
    const unit_id = v.unitId(ctx.number_pool);
    const unit: ?[]const u8 = if (unit_id == .none) null else ctx.intern_pool.get(unit_id);
    return value_format.formatNumberWithUnit(ctx.allocator, v.asF64(ctx.number_pool), unit) catch error.OutOfMemory;
}

fn fail(ctx: *BuiltinContext, comptime fmt: []const u8, args: anytype) (Explained || shared.BuiltinError) {
    _ = ctx;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.Explained;
    error_format.setContextMessage(msg);
    return error.Explained;
}
