const std = @import("std");
const data = @import("data.zig");

const CallableTarget = data.CallableTarget;
const UseBinding = data.UseBinding;
const VarTarget = data.VarTarget;

pub fn identifierEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca == cb) continue;
        if ((ca == '-' and cb == '_') or (ca == '_' and cb == '-')) continue;
        return false;
    }
    return true;
}

fn hasIdentifierAliasChar(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "-_") != null;
}

fn hasMultipleIdentifierAliasChars(name: []const u8) bool {
    var seen = false;
    for (name) |c| {
        if (c != '-' and c != '_') continue;
        if (seen) return true;
        seen = true;
    }
    return false;
}

pub fn hasMixedIdentifierAliasChars(name: []const u8) bool {
    var seen_dash = false;
    var seen_underscore = false;
    for (name) |c| {
        if (c == '-') {
            seen_dash = true;
        } else if (c == '_') {
            seen_underscore = true;
        }
    }
    return seen_dash and seen_underscore;
}

const insensitive_lookup_scratch_len = 256;

fn makeIdentifierAliasVariant(
    name: []const u8,
    from: u8,
    to: u8,
    scratch: []u8,
) ?[]const u8 {
    if (name.len > scratch.len) return null;
    var changed = false;
    for (name, 0..) |c, i| {
        if (c == from) {
            scratch[i] = to;
            changed = true;
        } else {
            scratch[i] = c;
        }
    }
    return if (changed) scratch[0..name.len] else null;
}

fn makeBothIdentifierAliasVariants(
    name: []const u8,
    scratch_dash: []u8,
    scratch_underscore: []u8,
) struct { has_alias_char: bool, has_multiple_alias_chars: bool, has_underscore: bool, has_dash: bool } {
    if (name.len > scratch_dash.len) {
        return .{
            .has_alias_char = false,
            .has_multiple_alias_chars = false,
            .has_underscore = false,
            .has_dash = false,
        };
    }
    var first_alias_index = name.len;
    for (name, 0..) |c, i| {
        if (c == '_' or c == '-') {
            first_alias_index = i;
            break;
        }
    }
    if (first_alias_index == name.len) {
        return .{
            .has_alias_char = false,
            .has_multiple_alias_chars = false,
            .has_underscore = false,
            .has_dash = false,
        };
    }
    if (first_alias_index > 0) {
        @memcpy(scratch_dash[0..first_alias_index], name[0..first_alias_index]);
        @memcpy(scratch_underscore[0..first_alias_index], name[0..first_alias_index]);
    }

    var has_underscore = false;
    var has_dash = false;
    var has_multiple_alias_chars = false;
    var saw_alias_char = false;
    for (name[first_alias_index..], first_alias_index..) |c, i| {
        if (c == '_') {
            scratch_dash[i] = '-';
            scratch_underscore[i] = c;
            if (saw_alias_char) has_multiple_alias_chars = true else saw_alias_char = true;
            has_underscore = true;
        } else if (c == '-') {
            scratch_dash[i] = c;
            scratch_underscore[i] = '_';
            if (saw_alias_char) has_multiple_alias_chars = true else saw_alias_char = true;
            has_dash = true;
        } else {
            scratch_dash[i] = c;
            scratch_underscore[i] = c;
        }
    }
    return .{
        .has_alias_char = true,
        .has_multiple_alias_chars = has_multiple_alias_chars,
        .has_underscore = has_underscore,
        .has_dash = has_dash,
    };
}

pub fn lookupStringMapIdentifierInsensitive(
    comptime V: type,
    map: *const std.StringHashMapUnmanaged(V),
    name: []const u8,
) ?V {
    return lookupStringMapIdentifierInsensitiveEx(V, map, name, true);
}

pub fn lookupStringMapIdentifierInsensitiveNoMixedKeys(
    comptime V: type,
    map: *const std.StringHashMapUnmanaged(V),
    name: []const u8,
) ?V {
    return lookupStringMapIdentifierInsensitiveEx(V, map, name, false);
}

fn lookupStringMapIdentifierInsensitiveEx(
    comptime V: type,
    map: *const std.StringHashMapUnmanaged(V),
    name: []const u8,
    allow_mixed_key_fallback: bool,
) ?V {
    if (map.count() == 0) return null;
    if (map.get(name)) |value| return value;

    var scratch_dash: [insensitive_lookup_scratch_len]u8 = undefined;
    var scratch_underscore: [insensitive_lookup_scratch_len]u8 = undefined;
    const which = makeBothIdentifierAliasVariants(name, &scratch_dash, &scratch_underscore);
    if (!which.has_alias_char) return null;
    if (which.has_underscore) {
        if (map.get(scratch_dash[0..name.len])) |value| return value;
    }
    if (which.has_dash) {
        if (map.get(scratch_underscore[0..name.len])) |value| return value;
    }
    if (!allow_mixed_key_fallback) return null;
    if (!which.has_multiple_alias_chars) return null;

    var it = map.iterator();
    while (it.next()) |entry| {
        if (identifierEq(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn containsStringMapIdentifierInsensitive(
    comptime V: type,
    map: *const std.StringHashMapUnmanaged(V),
    name: []const u8,
) bool {
    if (map.count() == 0) return false;
    if (map.contains(name)) return true;
    if (!hasIdentifierAliasChar(name)) return false;

    var scratch: [insensitive_lookup_scratch_len]u8 = undefined;
    if (makeIdentifierAliasVariant(name, '_', '-', &scratch)) |alias| {
        if (map.contains(alias)) return true;
    }
    if (makeIdentifierAliasVariant(name, '-', '_', &scratch)) |alias| {
        if (map.contains(alias)) return true;
    }
    if (!hasMultipleIdentifierAliasChars(name)) return false;

    var it = map.iterator();
    while (it.next()) |entry| {
        if (identifierEq(entry.key_ptr.*, name)) return true;
    }
    return false;
}

pub fn lookupConfigVarTargetInsensitive(
    map: *const std.StringHashMapUnmanaged(VarTarget),
    name: []const u8,
) ?VarTarget {
    return lookupStringMapIdentifierInsensitive(VarTarget, map, name);
}

pub fn lookupCallableTargetInsensitive(
    map: *const std.StringHashMapUnmanaged(CallableTarget),
    name: []const u8,
) ?CallableTarget {
    return lookupStringMapIdentifierInsensitive(CallableTarget, map, name);
}

pub fn lookupIdentifierIdInsensitive(
    map: *const std.StringHashMapUnmanaged(u32),
    name: []const u8,
) ?u32 {
    return lookupStringMapIdentifierInsensitive(u32, map, name);
}

pub fn lookupIdentifierIdKeyInsensitive(
    map: *const std.StringHashMapUnmanaged(u32),
    name: []const u8,
) ?[]const u8 {
    if (map.getEntry(name)) |entry| return entry.key_ptr.*;
    var it = map.iterator();
    while (it.next()) |entry| {
        if (identifierEq(entry.key_ptr.*, name)) return entry.key_ptr.*;
    }
    return null;
}

pub fn lookupBoolFlagInsensitive(
    map: *const std.StringHashMapUnmanaged(bool),
    name: []const u8,
) ?bool {
    return lookupStringMapIdentifierInsensitive(bool, map, name);
}

pub fn lookupVoidFlagInsensitive(
    map: *const std.StringHashMapUnmanaged(void),
    name: []const u8,
) bool {
    return containsStringMapIdentifierInsensitive(void, map, name);
}

pub fn lookupUseBindingInsensitive(
    map: *const std.StringHashMapUnmanaged(UseBinding),
    name: []const u8,
) ?UseBinding {
    return lookupStringMapIdentifierInsensitive(UseBinding, map, name);
}
