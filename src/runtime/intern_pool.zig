const std = @import("std");
const perf = @import("perf.zig");

/// Opaque numeric handle for an interned string.
/// `none` (== 0) is a sentinel meaning "field not set"; `get(.none)` asserts.
/// Dynamic ids start at 256; ids 1..255 are reserved for well-known strings.
pub const InternId = enum(u32) {
    none = 0,
    _,
};

/// Arena-backed string interning pool.
/// All interned slices are stable for the lifetime of the arena.
/// Not thread-safe (compile is single-threaded).
pub const InternPool = struct {
    /// id  ->  slice.  Indexed by `@intFromEnum(id)`.
    /// Entry 0 is a dummy for `InternId.none` (never returned by `intern`).
    strings: std.ArrayListUnmanaged([]const u8),

    /// id  ->  cheap lexical metadata for the corresponding string.
    ///
    /// Kept parallel to `strings`.  Equality and map-key hot paths ask "does
    /// this quoted string contain a backslash escape?" repeatedly; computing
    /// that once when the stable string is stored avoids rescanning the same
    /// bytes during deep list/map equality.
    string_meta: std.ArrayListUnmanaged(u8),

    /// string  ->  id reverse lookup.
    index: std.StringHashMapUnmanaged(InternId),

    arena: std.mem.Allocator,

    /// Initialise the pool.
    /// `arena` must outlive the pool. Slot 0 is the `.none` sentinel.
    /// Well-known strings are pre-interned in a fixed order (ids 1..N).
    pub fn init(arena: std.mem.Allocator) std.mem.Allocator.Error!InternPool {
        var pool: InternPool = .{
            .strings = .empty,
            .string_meta = .empty,
            .index = .{},
            .arena = arena,
        };

        // Slot 0: sentinel for InternId.none -- never returned by intern().
        try pool.strings.append(arena, "");
        try pool.string_meta.append(arena, 0);

        // Pre-intern all well-known strings in the fixed order defined by
        // well_known.strings.  The resulting id must equal well_known.id(i).
        for (well_known.strings, 0..) |s, i| {
            const interned = try pool.intern(s);
            // Comptime cannot run this assert, but runtime catches mismatches.
            std.debug.assert(interned == well_known.id(i));
        }

        return pool;
    }

    /// Deduplicate and return the canonical InternId for `s`.
    /// Allocates into the arena on first encounter.
    pub fn intern(self: *InternPool, s: []const u8) std.mem.Allocator.Error!InternId {
        perf.note(.intern_lookup);
        // Use getOrPut so misses hash the input string only once. The old
        // get()+put() path hashed large generated strings twice; extension-heavy
        // inputs can produce tens of thousands of long unique strings.
        const gop = try self.index.getOrPutAdapted(self.arena, s, std.hash_map.StringContext{});
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer self.index.removeByPtr(gop.key_ptr);

        perf.bump(.intern_miss, s.len);
        // Dupe into arena so the slice is stable, then replace the temporary
        // uninitialized lookup key slot with the owned copy.
        const copy = try self.arena.dupe(u8, s);
        const new_id: InternId = @enumFromInt(@as(u32, @intCast(self.strings.items.len)));
        errdefer self.arena.free(copy);
        try self.strings.ensureUnusedCapacity(self.arena, 1);
        try self.string_meta.ensureUnusedCapacity(self.arena, 1);
        self.strings.appendAssumeCapacity(copy);
        self.string_meta.appendAssumeCapacity(computeStringMeta(copy));
        gop.key_ptr.* = copy;
        gop.value_ptr.* = new_id;
        return new_id;
    }

    /// Store a generated string without reverse-indexing it.
    ///
    /// This is for very large intermediate runtime strings that are expected
    /// to be unique (for example repeated Sass string concatenation building a
    /// CSS shadow list). `get(id)` works normally; later `intern()` of the same
    /// bytes may return a different id, so semantic equality must compare bytes
    /// after the id fast path.
    pub fn storeFresh(self: *InternPool, s: []const u8) std.mem.Allocator.Error!InternId {
        const copy = try self.arena.dupe(u8, s);
        const new_id: InternId = @enumFromInt(@as(u32, @intCast(self.strings.items.len)));
        errdefer self.arena.free(copy);
        try self.strings.ensureUnusedCapacity(self.arena, 1);
        try self.string_meta.ensureUnusedCapacity(self.arena, 1);
        self.strings.appendAssumeCapacity(copy);
        self.string_meta.appendAssumeCapacity(computeStringMeta(copy));
        return new_id;
    }

    /// Return the string for `id`.  Asserts `id != .none`.
    pub fn get(self: *const InternPool, id: InternId) []const u8 {
        std.debug.assert(id != .none);
        return self.strings.items[@intFromEnum(id)];
    }

    /// True when the stored bytes contain `\`.
    pub fn hasBackslash(self: *const InternPool, id: InternId) bool {
        std.debug.assert(id != .none);
        return (self.string_meta.items[@intFromEnum(id)] & string_meta_has_backslash) != 0;
    }

    /// Meta byte with the lazy calc bits guaranteed computed. Test the result
    /// against `meta_has_calc_paren` / `meta_has_calc_marker`. Computed on
    /// first query and cached in `string_meta`, so equality hot paths scan
    /// each distinct string at most once instead of on every comparison.
    /// Eager computation at intern time would instead scan every interned
    /// string, including large generated output strings that never
    /// participate in equality.
    pub inline fn calcMetaByte(self: *InternPool, id: InternId) u8 {
        std.debug.assert(id != .none);
        const idx: usize = @intFromEnum(id);
        const meta = self.string_meta.items[idx];
        if ((meta & string_meta_calc_scanned) != 0) return meta;
        return self.calcMetaSlow(idx);
    }

    fn calcMetaSlow(self: *InternPool, idx: usize) u8 {
        var meta = self.string_meta.items[idx];
        const s = self.strings.items[idx];
        if (std.mem.find(u8, s, "calc(") != null) meta |= string_meta_has_calc_paren;
        if (std.mem.startsWith(u8, s, calc_arg_marker) or std.mem.startsWith(u8, s, calc_interp_marker)) {
            meta |= string_meta_has_calc_marker;
        }
        meta |= string_meta_calc_scanned;
        self.string_meta.items[idx] = meta;
        return meta;
    }

    /// True when the stored bytes contain the substring `calc(` (lazy).
    pub inline fn hasCalcParen(self: *InternPool, id: InternId) bool {
        return (self.calcMetaByte(id) & string_meta_has_calc_paren) != 0;
    }

    /// True when the stored bytes start with one of the internal calc
    /// argument/interpolation marker prefixes (`\x01zsass-calc-...`) (lazy).
    pub inline fn hasCalcMarkerPrefix(self: *InternPool, id: InternId) bool {
        return (self.calcMetaByte(id) & string_meta_has_calc_marker) != 0;
    }

    /// True if `a` and `b` refer to the same string (O(1)).
    pub fn eq(a: InternId, b: InternId) bool {
        return a == b;
    }

    /// Free backing storage: all interned string copies, the strings list, and the index map.
    /// Does NOT free the arena object itself -- the caller owns it.
    /// When `alloc` is an arena allocator the individual string frees are no-ops and
    /// arena.deinit() reclaims everything in bulk; this function is still safe to call.
    pub fn deinit(self: *InternPool, alloc: std.mem.Allocator) void {
        // Free each interned string copy (slot 0 is the empty sentinel ""; skip it).
        // Covers both well-known and dynamic entries. index keys point into the same
        // duped memory, so we must NOT call index.deinit before freeing strings.
        for (self.strings.items[1..]) |s| {
            alloc.free(s);
        }
        self.strings.deinit(alloc);
        self.string_meta.deinit(alloc);
        // index keys already freed above; just free the HashMap backing array.
        self.index.deinit(alloc);
    }
};

const string_meta_has_backslash: u8 = 1 << 0;
/// Public masks for `calcMetaByte` results.
pub const meta_has_calc_paren: u8 = 1 << 1;
pub const meta_has_calc_marker: u8 = 1 << 2;
const string_meta_has_calc_paren = meta_has_calc_paren;
const string_meta_has_calc_marker = meta_has_calc_marker;
const string_meta_calc_scanned: u8 = 1 << 3;

// Internal runtime marker prefixes (kept in sync with calc_utils / builtin
// shared constants; they are stable engine-internal sentinels).
const calc_arg_marker = "\x01zsass-calc-arg:";
const calc_interp_marker = "\x01zsass-calc-interp:";

fn computeStringMeta(s: []const u8) u8 {
    var meta: u8 = 0;
    if (std.mem.findScalar(u8, s, '\\') != null) meta |= string_meta_has_backslash;
    return meta;
}

// ---------------------------------------------------------------------------
// Well-known string constants
//
// The `strings` array is the single source of truth.
// `id(i)` maps index  ->  InternId (slot 0 is the .none sentinel, so offset +1).
// Add entries to `strings` and add a corresponding `pub const` below.
// TODO: expand well-known list as needed.
// ---------------------------------------------------------------------------

const well_known = struct {
    const strings = [_][]const u8{
        // sigils (indices 0-3)
        "$",
        "&",
        "*",
        "/",
        // at-rule names (indices 4-26)
        "media",
        "supports",
        "keyframes",
        "font-face",
        "page",
        "import",
        "use",
        "forward",
        "mixin",
        "include",
        "function",
        "if",
        "else",
        "each",
        "for",
        "while",
        "return",
        "extend",
        "at-root",
        "debug",
        "warn",
        "error",
        "content",
        // well-known module names (indices 27-33)
        "math",
        "color",
        "string",
        "list",
        "map",
        "selector",
        "meta",
        // well-known units (indices 34-42)
        "px",
        "em",
        "rem",
        "%",
        "deg",
        "rad",
        "turn",
        "s",
        "ms",
        // well-known pseudo names (indices 43-51)
        "hover",
        "focus",
        "root",
        "before",
        "after",
        "is",
        "where",
        "not",
        "has",
    };

    /// Convert a 0-based index in `strings` to the corresponding InternId.
    /// Slot 0 of the pool is the .none sentinel, so ids start at 1.
    /// Works at both comptime and runtime.
    fn id(idx: usize) InternId {
        return @enumFromInt(@as(u32, @intCast(idx + 1)));
    }

    // sigils
    const dollar_sign: InternId = id(0); // "$"
    const ampersand: InternId = id(1); // "&"
    const star: InternId = id(2); // "*"
    const slash: InternId = id(3); // "/"

    // at-rule names
    const media: InternId = id(4);
    const supports: InternId = id(5);
    const keyframes: InternId = id(6);
    const font_face: InternId = id(7);
    const page: InternId = id(8);
    const import: InternId = id(9);
    const use: InternId = id(10);
    const forward: InternId = id(11);
    const mixin: InternId = id(12);
    const include: InternId = id(13);
    const function: InternId = id(14);
    const @"if": InternId = id(15);
    const @"else": InternId = id(16);
    const each: InternId = id(17);
    const @"for": InternId = id(18);
    const @"while": InternId = id(19);
    const @"return": InternId = id(20);
    const extend: InternId = id(21);
    const at_root: InternId = id(22);
    const debug: InternId = id(23);
    const warn: InternId = id(24);
    const @"error": InternId = id(25);
    const content: InternId = id(26);

    // module names
    const math: InternId = id(27);
    const color: InternId = id(28);
    const string: InternId = id(29);
    const list: InternId = id(30);
    const map: InternId = id(31);
    const selector: InternId = id(32);
    const meta: InternId = id(33);

    // units
    const unit_px: InternId = id(34);
    const unit_em: InternId = id(35);
    const unit_rem: InternId = id(36);
    const unit_percent: InternId = id(37);
    const unit_deg: InternId = id(38);
    const unit_rad: InternId = id(39);
    const unit_turn: InternId = id(40);
    const unit_s: InternId = id(41);
    const unit_ms: InternId = id(42);

    // pseudo-class names
    const pseudo_hover: InternId = id(43);
    const pseudo_focus: InternId = id(44);
    const pseudo_root: InternId = id(45);
    const pseudo_before: InternId = id(46);
    const pseudo_after: InternId = id(47);
    const pseudo_is: InternId = id(48);
    const pseudo_where: InternId = id(49);
    const pseudo_not: InternId = id(50);
    const pseudo_has: InternId = id(51);
};

pub const intern_ampersand: InternId = well_known.ampersand;

/// Comptime lookup of a pre-interned well-known string's id. Lets hot paths
/// use a constant instead of hashing the same literal on every call.
/// Compile error when `s` is not in the well-known table.
pub fn wellKnownId(comptime s: []const u8) InternId {
    inline for (well_known.strings, 0..) |w, i| {
        if (comptime std.mem.eql(u8, w, s)) return well_known.id(i);
    }
    @compileError("not a well-known intern string: " ++ s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "intern basic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pool = try InternPool.init(arena);
    const a = try pool.intern("foo");
    const b = try pool.intern("foo");
    try std.testing.expect(a == b);
    try std.testing.expectEqualStrings("foo", pool.get(a));
}

test "well-known ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pool = try InternPool.init(arena);
    try std.testing.expectEqual(well_known.dollar_sign, try pool.intern("$"));
    try std.testing.expectEqualStrings("$", pool.get(well_known.dollar_sign));
}

test "intern deduplicates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pool = try InternPool.init(arena);
    const a = try pool.intern("hello");
    const b = try pool.intern("hello");
    try std.testing.expectEqual(a, b);
    const c = try pool.intern("world");
    try std.testing.expect(a != c);
}

test "intern empty string is not none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pool = try InternPool.init(arena);
    const empty_id = try pool.intern("");
    try std.testing.expect(empty_id != .none);
    try std.testing.expectEqualStrings("", pool.get(empty_id));
}

test "lazy calc meta bits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pool = try InternPool.init(arena);
    const plain = try pool.intern("text-weak-invert");
    const calc = try pool.intern("calc(1px + 2px)");
    const marked = try pool.intern(calc_arg_marker ++ "calc(1px)");
    try std.testing.expect(!pool.hasCalcParen(plain));
    try std.testing.expect(!pool.hasCalcMarkerPrefix(plain));
    try std.testing.expect(pool.hasCalcParen(calc));
    try std.testing.expect(!pool.hasCalcMarkerPrefix(calc));
    try std.testing.expect(pool.hasCalcMarkerPrefix(marked));
    try std.testing.expect(pool.hasCalcParen(marked));
    // Second query reads the cached scanned bits.
    try std.testing.expect(pool.hasCalcParen(calc));
    try std.testing.expect(!pool.hasCalcParen(plain));
}

test "wellKnownId resolves pre-interned strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pool = try InternPool.init(arena);
    try std.testing.expectEqual(wellKnownId("%"), try pool.intern("%"));
    try std.testing.expectEqual(wellKnownId("deg"), try pool.intern("deg"));
}

test "all well-known strings round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pool = try InternPool.init(arena);
    for (well_known.strings, 0..) |s, i| {
        const expected_id = well_known.id(i);
        const got_id = try pool.intern(s);
        try std.testing.expectEqual(expected_id, got_id);
        try std.testing.expectEqualStrings(s, pool.get(got_id));
    }
}
