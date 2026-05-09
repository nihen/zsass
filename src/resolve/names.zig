const std = @import("std");
const data = @import("data.zig");
const name_lookup = @import("name_lookup.zig");

const ResolvedProgram = data.ResolvedProgram;

pub const identifierEqSass = name_lookup.identifierEq;

pub fn defaultNamespaceForUse(url: []const u8) []const u8 {
    const base0 = std.fs.path.basename(url);
    var base = base0;
    if (std.mem.endsWith(u8, base, ".scss")) base = base[0 .. base.len - ".scss".len];
    if (std.mem.endsWith(u8, base, ".sass")) base = base[0 .. base.len - ".sass".len];
    if (base.len > 0 and base[0] == '_') base = base[1..];
    if (std.mem.indexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    return base;
}

/// Is it a URL such as `sass:color` that is treated as builtin without being sent to file search? Returns short name slice after `InternPool` / static `sass:`.
pub fn builtinModuleUrlToShortName(url: []const u8) ?[]const u8 {
    const p = "sass:";
    if (!std.mem.startsWith(u8, url, p)) return null;
    const rest = url[p.len..];
    const allowed = [_][]const u8{
        "color", "list", "map", "math", "meta", "selector", "string",
    };
    inline for (allowed) |name| {
        if (std.mem.eql(u8, rest, name)) return name;
    }
    return null;
}

pub fn isPrivateMemberName(name: []const u8) bool {
    return name.len != 0 and (name[0] == '_' or name[0] == '-');
}

pub fn forwardMatchesVarToken(token: []const u8, name: []const u8) bool {
    if (token.len == 0 or token[0] != '$') return false;
    return identifierEqSass(token[1..], name);
}

pub fn forwardMatchesPlainToken(token: []const u8, name: []const u8) bool {
    return identifierEqSass(token, name);
}

fn forwardListContainsVar(list: []const []const u8, name: []const u8) bool {
    for (list) |tok| {
        if (forwardMatchesVarToken(tok, name)) return true;
    }
    return false;
}

fn forwardListContainsPlain(list: []const []const u8, name: []const u8) bool {
    for (list) |tok| {
        if (forwardMatchesPlainToken(tok, name)) return true;
    }
    return false;
}

pub fn forwardAllowsVar(name: []const u8, show: ?[]const []const u8, hide: ?[]const []const u8) bool {
    if (show) |s| {
        if (!forwardListContainsVar(s, name)) return false;
    }
    if (hide) |h| {
        if (forwardListContainsVar(h, name)) return false;
    }
    return true;
}

pub fn forwardAllowsPlain(name: []const u8, show: ?[]const []const u8, hide: ?[]const []const u8) bool {
    if (show) |s| {
        if (!forwardListContainsPlain(s, name)) return false;
    }
    if (hide) |h| {
        if (forwardListContainsPlain(h, name)) return false;
    }
    return true;
}

pub fn withForwardPrefix(prog: *ResolvedProgram, prefix: ?[]const u8, name: []const u8) ![]const u8 {
    if (prefix) |p| return std.fmt.allocPrint(prog.arena.allocator(), "{s}{s}", .{ p, name });
    return name;
}
