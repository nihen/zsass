const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const units = @import("../runtime/units.zig");

const toCanonicalUnit = units.toCanonical;
const fromCanonicalUnit = units.fromCanonical;
const unitsMatch = units.unitsMatch;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Operator = enum {
    add,
    subtract,
    multiply,
    divide,

    pub fn symbol(self: Operator) []const u8 {
        return switch (self) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
        };
    }

    fn precedence(self: Operator) u2 {
        return switch (self) {
            .add, .subtract => 0,
            .multiply, .divide => 1,
        };
    }
};

pub const CalcValue = union(enum) {
    /// `unit_owned == true` means this `CalcValue` owns the storage backing
    /// `unit` and `freeCalcValueInner` must `allocator.free(unit)` on
    /// destruction. `unit_owned == false` indicates a borrowed slice
    /// (typically pointing at the original parser source or at another
    /// `CalcValue` whose lifetime outlives this node), and the unit must
    /// not be freed here.
    number: struct { value: f64, unit: ?[]const u8, unit_owned: bool = false },
    operation: struct {
        op: Operator,
        left: *const CalcValue,
        right: *const CalcValue,
    },
    function_call: struct {
        name: []const u8,
        args: []const CalcValue,
    },
    variable: []const u8,
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0C';
}

// ---------------------------------------------------------------------------
// Calc tokeniser (internal)
// ---------------------------------------------------------------------------

const CalcToken = union(enum) {
    number: struct { value: f64, unit: ?[]const u8 },
    op: Operator,
    lparen: void,
    rparen: void,
    comma: void,
    ident: []const u8,
    invalid: u8,
    eof: void,
};

const CalcTokenizer = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) CalcTokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn skipWhitespace(self: *CalcTokenizer) void {
        while (self.pos < self.src.len and isWhitespace(self.src[self.pos])) {
            self.pos += 1;
        }
    }

    fn next(self: *CalcTokenizer) CalcToken {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return .eof;

        const c = self.src[self.pos];

        switch (c) {
            '(' => {
                self.pos += 1;
                return .lparen;
            },
            ')' => {
                self.pos += 1;
                return .rparen;
            },
            ',' => {
                self.pos += 1;
                return .comma;
            },
            '+' => {
                self.pos += 1;
                return .{ .op = .add };
            },
            '*' => {
                self.pos += 1;
                return .{ .op = .multiply };
            },
            '/' => {
                self.pos += 1;
                return .{ .op = .divide };
            },
            '-' => {
                if (self.pos + 1 < self.src.len and
                    (self.src[self.pos + 1] == '-' or isIdentStart(self.src[self.pos + 1])))
                {
                    return self.readIdent();
                }
                // Disambiguate unary minus (start of number) vs binary subtract.
                // If next char is digit or '.', and previous non-ws token was not a
                // number/rparen, treat as part of a number.
                if (self.pos + 1 < self.src.len and (isDigit(self.src[self.pos + 1]) or self.src[self.pos + 1] == '.')) {
                    // Peek backwards to decide.
                    if (self.isUnaryContext()) {
                        return self.readNumber();
                    }
                }
                self.pos += 1;
                return .{ .op = .subtract };
            },
            '.' => return self.readNumber(),
            else => {
                if (isDigit(c)) return self.readNumber();
                if (isIdentStart(c) or c == '-') return self.readIdent();
                self.pos += 1;
                return .{ .invalid = c };
            },
        }
    }

    /// Returns true when we are in a context where `-` should be treated as
    /// unary (i.e. beginning of a negative number).
    fn isUnaryContext(self: *CalcTokenizer) bool {
        // Walk backwards over whitespace to find previous meaningful character.
        if (self.pos == 0) return true;
        var p = self.pos - 1;
        while (p > 0 and isWhitespace(self.src[p])) p -= 1;
        const prev = self.src[p];
        // After a closing paren or digit/letter (end of number/ident) it is binary.
        if (prev == ')') return false;
        if (isDigit(prev) or isIdentChar(prev)) return false;
        return true;
    }

    fn readNumber(self: *CalcTokenizer) CalcToken {
        const start = self.pos;
        // optional leading minus
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        // integer part
        while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        // fractional part
        if (self.pos < self.src.len and self.src[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        const num_str = self.src[start..self.pos];
        const value = std.fmt.parseFloat(f64, num_str) catch return .{ .invalid = self.src[start] };

        // unit (e.g. px, %, em, rem, vw, vh ...)
        const unit_start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '%') {
            self.pos += 1;
        } else {
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        }
        const unit: ?[]const u8 = if (self.pos > unit_start)
            self.src[unit_start..self.pos]
        else
            null;

        return .{ .number = .{ .value = value, .unit = unit } };
    }

    fn readIdent(self: *CalcTokenizer) CalcToken {
        const start = self.pos;
        // Allow leading - for CSS custom properties / var()
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        return .{ .ident = self.src[start..self.pos] };
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '-';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn parseCalcConstantIdent(name: []const u8) ?f64 {
    if (std.ascii.eqlIgnoreCase(name, "pi")) return std.math.pi;
    if (std.ascii.eqlIgnoreCase(name, "+pi")) return std.math.pi;
    if (std.ascii.eqlIgnoreCase(name, "-pi")) return -std.math.pi;
    if (std.ascii.eqlIgnoreCase(name, "e")) return std.math.e;
    if (std.ascii.eqlIgnoreCase(name, "+e")) return std.math.e;
    if (std.ascii.eqlIgnoreCase(name, "-e")) return -std.math.e;
    if (std.ascii.eqlIgnoreCase(name, "infinity")) return std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(name, "+infinity")) return std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(name, "-infinity")) return -std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(name, "nan")) return std.math.nan(f64);
    if (std.ascii.eqlIgnoreCase(name, "+nan")) return std.math.nan(f64);
    if (std.ascii.eqlIgnoreCase(name, "-nan")) return std.math.nan(f64);
    return null;
}

// ---------------------------------------------------------------------------
// Calc parser  (recursive-descent)
// ---------------------------------------------------------------------------

const ParseError = error{
    UnexpectedToken,
    UnterminatedGroup,
    TrailingTokens,
    OutOfMemory,
};

const Parser = struct {
    tokenizer: CalcTokenizer,
    current: CalcToken,
    allocator: Allocator,

    fn init(allocator: Allocator, input: []const u8) Parser {
        var tokenizer = CalcTokenizer.init(input);
        const first = tokenizer.next();
        return .{
            .tokenizer = tokenizer,
            .current = first,
            .allocator = allocator,
        };
    }

    fn advance(self: *Parser) CalcToken {
        const prev = self.current;
        self.current = self.tokenizer.next();
        return prev;
    }

    fn makeOperationNode(
        self: *Parser,
        op: Operator,
        left: *CalcValue,
        right: *CalcValue,
    ) ParseError!*CalcValue {
        const node = try self.allocator.create(CalcValue);
        node.* = .{ .operation = .{
            .op = op,
            .left = left,
            .right = right,
        } };
        return node;
    }

    // expression = term (('+' | '-') term)*
    fn parseExpression(self: *Parser) ParseError!*CalcValue {
        var left = try self.parseTerm();
        while (true) {
            switch (self.current) {
                .op => |op| {
                    if (op == .add or op == .subtract) {
                        _ = self.advance();
                        const right = try self.parseTerm();
                        left = try self.makeOperationNode(op, left, right);
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
        return left;
    }

    // term = atom (('*' | '/') atom)*
    fn parseTerm(self: *Parser) ParseError!*CalcValue {
        var left = try self.parseAtom();
        while (true) {
            switch (self.current) {
                .op => |op| {
                    if (op == .multiply or op == .divide) {
                        _ = self.advance();
                        const right = try self.parseAtom();
                        left = try self.makeOperationNode(op, left, right);
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
        return left;
    }

    // atom = number | '(' expression ')' | ident '(' args ')' | variable
    fn parseAtom(self: *Parser) ParseError!*CalcValue {
        if (self.current == .number) {
            const n = self.current.number;
            _ = self.advance();
            const node = try self.allocator.create(CalcValue);
            node.* = .{ .number = .{ .value = n.value, .unit = n.unit } };
            return node;
        }
        switch (self.current) {
            .lparen => {
                _ = self.advance(); // consume '('
                const expr = try self.parseExpression();
                // consume ')'
                switch (self.current) {
                    .rparen => _ = self.advance(),
                    else => return ParseError.UnterminatedGroup,
                }
                return expr;
            },
            .ident => |name| {
                _ = self.advance();
                if (parseCalcConstantIdent(name)) |constant| {
                    const node = try self.allocator.create(CalcValue);
                    node.* = .{ .number = .{ .value = constant, .unit = null } };
                    return node;
                }
                // Check for function call: ident '('
                switch (self.current) {
                    .lparen => {
                        _ = self.advance(); // consume '('
                        return try self.parseFunctionCall(name);
                    },
                    else => {
                        // Treat as variable
                        const node = try self.allocator.create(CalcValue);
                        node.* = .{ .variable = name };
                        return node;
                    },
                }
            },
            .op => |op| {
                // Handle unary +/- at atom level
                if (op == .add) {
                    _ = self.advance();
                    return self.parseAtom();
                }
                if (op == .subtract) {
                    _ = self.advance();
                    const inner = try self.parseAtom();
                    // Optimise: if inner is a plain number, just negate
                    // it. The original `inner` node is replaced by the
                    // negated copy -- transfer the unit (and its
                    // ownership flag) so we do not leak the original
                    // node nor double-free its unit slice.
                    if (inner.* == .number) {
                        const n = inner.number;
                        const node = try self.allocator.create(CalcValue);
                        node.* = .{ .number = .{ .value = -n.value, .unit = n.unit, .unit_owned = n.unit_owned } };
                        var inner_mut: *CalcValue = inner;
                        inner_mut.number.unit_owned = false;
                        freeCalcValueInner(self.allocator, inner);
                        self.allocator.destroy(inner_mut);
                        return node;
                    }
                    // -expr  =>  0 - expr
                    const zero = try self.allocator.create(CalcValue);
                    zero.* = .{ .number = .{ .value = 0.0, .unit = null, .unit_owned = false } };
                    const node = try self.allocator.create(CalcValue);
                    node.* = .{ .operation = .{
                        .op = .subtract,
                        .left = zero,
                        .right = inner,
                    } };
                    return node;
                }
                return ParseError.UnexpectedToken;
            },
            .invalid => return ParseError.UnexpectedToken,
            else => return ParseError.UnexpectedToken,
        }
    }

    fn parseFunctionCall(self: *Parser, name: []const u8) ParseError!*CalcValue {
        // For calc(), parse the inner expression directly.
        if (std.mem.eql(u8, name, "calc")) {
            const inner = try self.parseExpression();
            // consume ')'
            switch (self.current) {
                .rparen => _ = self.advance(),
                else => return ParseError.UnterminatedGroup,
            }
            return inner;
        }
        // For var(), treat argument as variable name.
        if (std.mem.eql(u8, name, "var")) {
            switch (self.current) {
                .ident => |var_name| {
                    _ = self.advance();
                    // consume ')'
                    switch (self.current) {
                        .rparen => _ = self.advance(),
                        else => return ParseError.UnterminatedGroup,
                    }
                    const args_slice = try self.allocator.alloc(CalcValue, 1);
                    args_slice[0] = .{ .variable = var_name };
                    const node = try self.allocator.create(CalcValue);
                    node.* = .{ .function_call = .{
                        .name = "var",
                        .args = args_slice,
                    } };
                    return node;
                },
                else => {
                    return ParseError.UnexpectedToken;
                },
            }
        }

        // min, max, clamp, etc. - parse comma-separated arguments.
        var args: std.ArrayList(CalcValue) = .empty;
        defer args.deinit(self.allocator);

        // First arg (always present unless empty parens)
        switch (self.current) {
            .rparen => {},
            else => {
                const first = try self.parseExpression();
                try args.append(self.allocator, first.*);
                self.allocator.destroy(first);
            },
        }

        while (true) {
            switch (self.current) {
                .comma => {
                    _ = self.advance();
                    const arg = try self.parseExpression();
                    try args.append(self.allocator, arg.*);
                    self.allocator.destroy(arg);
                },
                else => break,
            }
        }

        // consume ')'
        switch (self.current) {
            .rparen => _ = self.advance(),
            else => return ParseError.UnterminatedGroup,
        }

        const args_slice = try self.allocator.dupe(CalcValue, args.items);
        const node = try self.allocator.create(CalcValue);
        node.* = .{ .function_call = .{
            .name = name,
            .args = args_slice,
        } };
        return node;
    }
};

// ---------------------------------------------------------------------------
// Public API - parseCalc
// ---------------------------------------------------------------------------

pub fn parseCalc(allocator: Allocator, input: []const u8) !*CalcValue {
    var parser = Parser.init(allocator, input);
    const value = try parser.parseExpression();
    switch (parser.current) {
        .eof => return value,
        else => {
            freeCalcValue(allocator, value);
            allocator.destroy(value);
            return ParseError.TrailingTokens;
        },
    }
}

// ---------------------------------------------------------------------------
// Public API - simplify
// ---------------------------------------------------------------------------

/// Take ownership of `src.number.unit` and destroy `src` itself. The
/// returned (unit, owned) pair tells the caller whether the slice it
/// just received was previously owned by `src`'s allocator (the caller
/// must keep it alive and ultimately free it) or borrowed (the caller
/// must continue treating it as borrowed). After the call `src` is
/// invalid; the helper disarms `src.number.unit_owned` before the
/// teardown so the slice is never freed underneath the transfer.
const TakenUnit = struct { unit: ?[]const u8, owned: bool };
fn takeNumberUnitAndDestroy(allocator: Allocator, src: *const CalcValue) TakenUnit {
    std.debug.assert(src.* == .number);
    const u = src.number.unit;
    const owned = src.number.unit_owned;
    var mut: *CalcValue = @constCast(src);
    mut.number.unit_owned = false;
    freeCalcValueInner(allocator, src);
    allocator.destroy(mut);
    return .{ .unit = u, .owned = owned };
}

/// Pick a winning unit from the two `TakenUnit`s a left/right destroy
/// produced. Both cannot be both owned and surviving -- only one slice
/// can land in the new fold result -- so the loser's owned slice is
/// freed here.
fn pickFoldUnit(allocator: Allocator, left: TakenUnit, right: TakenUnit) TakenUnit {
    if (left.unit) |_| {
        if (right.owned) {
            if (right.unit) |ru| allocator.free(ru);
        }
        return left;
    }
    return right;
}

/// Free the second unit when the fold result intentionally drops both
/// (e.g. `unitless / unitless` returns a unitless number).
fn discardBothUnits(allocator: Allocator, left: TakenUnit, right: TakenUnit) void {
    if (left.owned) {
        if (left.unit) |u| allocator.free(u);
    }
    if (right.owned) {
        if (right.unit) |u| allocator.free(u);
    }
}

pub fn simplify(allocator: Allocator, value: *const CalcValue) !*CalcValue {
    if (value.* == .number) {
        const node = try allocator.create(CalcValue);
        node.* = value.*;
        return node;
    }
    switch (value.*) {
        .variable => {
            const node = try allocator.create(CalcValue);
            node.* = value.*;
            return node;
        },
        .operation => |op| {
            const left = try simplify(allocator, op.left);
            // Disarming `*_alive` after a fold consumes left/right keeps
            // the errdefer below from freeing memory the fold is
            // currently moving. Any error _before_ the consume runs the
            // errdefer and frees both children.
            var left_alive: bool = true;
            errdefer if (left_alive) {
                freeCalcValueInner(allocator, left);
                allocator.destroy(@as(*CalcValue, @constCast(left)));
            };
            const right = try simplify(allocator, op.right);
            var right_alive: bool = true;
            errdefer if (right_alive) {
                freeCalcValueInner(allocator, right);
                allocator.destroy(@as(*CalcValue, @constCast(right)));
            };

            // Try constant folding when both sides are plain numbers.
            const left_num = if (left.* == .number) left.number else null;
            const right_num = if (right.* == .number) right.number else null;

            if (left_num != null and right_num != null) {
                const ln = left_num.?;
                const rn = right_num.?;

                switch (op.op) {
                    .add, .subtract => {
                        if (unitsMatch(ln.unit, rn.unit)) {
                            const result_val: f64 = if (op.op == .add) ln.value + rn.value else ln.value - rn.value;
                            // Allocate the result node before tearing
                            // down left/right so an OOM here is still
                            // recoverable by the errdefer above.
                            const node = try allocator.create(CalcValue);
                            const ltaken = takeNumberUnitAndDestroy(allocator, left);
                            left_alive = false;
                            const rtaken = takeNumberUnitAndDestroy(allocator, right);
                            right_alive = false;
                            const winner = pickFoldUnit(allocator, ltaken, rtaken);
                            node.* = .{ .number = .{ .value = result_val, .unit = winner.unit, .unit_owned = winner.owned } };
                            return node;
                        }
                        if (convertCompatibleUnit(rn.value, rn.unit, ln.unit)) |converted| {
                            const result_val: f64 = if (op.op == .add) ln.value + converted else ln.value - converted;
                            const node = try allocator.create(CalcValue);
                            const ltaken = takeNumberUnitAndDestroy(allocator, left);
                            left_alive = false;
                            const rtaken = takeNumberUnitAndDestroy(allocator, right);
                            right_alive = false;
                            // Result keeps left's unit; right's owned
                            // slice must be released here.
                            if (rtaken.owned) {
                                if (rtaken.unit) |u| allocator.free(u);
                            }
                            node.* = .{ .number = .{ .value = result_val, .unit = ltaken.unit, .unit_owned = ltaken.owned } };
                            return node;
                        }
                        // Different-unit zero additions/subtractions are
                        // still CSS calculations unless the units are
                        // directly comparable (handled above). For
                        // example official Sass CLI preserves `calc(15vw + 0px)`
                        // rather than folding it to `15vw`.
                    },
                    .multiply => {
                        // number * number-with-unit OR unit * unitless
                        if (ln.unit == null or rn.unit == null) {
                            const node = try allocator.create(CalcValue);
                            const ltaken = takeNumberUnitAndDestroy(allocator, left);
                            left_alive = false;
                            const rtaken = takeNumberUnitAndDestroy(allocator, right);
                            right_alive = false;
                            const winner = pickFoldUnit(allocator, ltaken, rtaken);
                            node.* = .{ .number = .{ .value = ln.value * rn.value, .unit = winner.unit, .unit_owned = winner.owned } };
                            return node;
                        }
                        const result = try combineUnits(allocator, ln.unit, rn.unit, .multiply);
                        const node = allocator.create(CalcValue) catch |err| {
                            if (result.unit_owned) if (result.unit) |u| allocator.free(u);
                            return err;
                        };
                        const ltaken = takeNumberUnitAndDestroy(allocator, left);
                        left_alive = false;
                        const rtaken = takeNumberUnitAndDestroy(allocator, right);
                        right_alive = false;
                        discardBothUnits(allocator, ltaken, rtaken);
                        node.* = .{ .number = .{ .value = ln.value * rn.value * result.factor, .unit = result.unit, .unit_owned = result.unit_owned } };
                        return node;
                    },
                    .divide => {
                        if (rn.unit == null and rn.value != 0) {
                            const node = try allocator.create(CalcValue);
                            const rtaken = takeNumberUnitAndDestroy(allocator, right);
                            right_alive = false;
                            const ltaken = takeNumberUnitAndDestroy(allocator, left);
                            left_alive = false;
                            _ = rtaken;
                            node.* = .{ .number = .{ .value = ln.value / rn.value, .unit = ltaken.unit, .unit_owned = ltaken.owned } };
                            return node;
                        }
                        if (unitsMatch(ln.unit, rn.unit) and rn.value != 0) {
                            const node = try allocator.create(CalcValue);
                            const ltaken = takeNumberUnitAndDestroy(allocator, left);
                            left_alive = false;
                            const rtaken = takeNumberUnitAndDestroy(allocator, right);
                            right_alive = false;
                            discardBothUnits(allocator, ltaken, rtaken);
                            node.* = .{ .number = .{ .value = ln.value / rn.value, .unit = null, .unit_owned = false } };
                            return node;
                        }
                        if (convertCompatibleUnit(rn.value, rn.unit, ln.unit)) |converted| {
                            if (converted != 0) {
                                const node = try allocator.create(CalcValue);
                                const ltaken = takeNumberUnitAndDestroy(allocator, left);
                                left_alive = false;
                                const rtaken = takeNumberUnitAndDestroy(allocator, right);
                                right_alive = false;
                                discardBothUnits(allocator, ltaken, rtaken);
                                node.* = .{ .number = .{ .value = ln.value / converted, .unit = null, .unit_owned = false } };
                                return node;
                            }
                        }
                        if (rn.unit != null and rn.value != 0) {
                            const result = try combineUnits(allocator, ln.unit, rn.unit, .divide);
                            const node = allocator.create(CalcValue) catch |err| {
                                if (result.unit_owned) if (result.unit) |u| allocator.free(u);
                                return err;
                            };
                            const ltaken = takeNumberUnitAndDestroy(allocator, left);
                            left_alive = false;
                            const rtaken = takeNumberUnitAndDestroy(allocator, right);
                            right_alive = false;
                            discardBothUnits(allocator, ltaken, rtaken);
                            node.* = .{ .number = .{ .value = ln.value / rn.value * result.factor, .unit = result.unit, .unit_owned = result.unit_owned } };
                            return node;
                        }
                    },
                }
            }

            // Could not fold - return simplified operation. The new node
            // takes ownership of `left` and `right`, so disarm the
            // errdefer guards before returning.
            const node = try allocator.create(CalcValue);
            node.* = .{ .operation = .{
                .op = op.op,
                .left = left,
                .right = right,
            } };
            left_alive = false;
            right_alive = false;
            return node;
        },
        .function_call => |fc| {
            const new_args = try allocator.alloc(CalcValue, fc.args.len);
            // Track how many slots have been populated so the errdefer
            // below frees only what we actually copied in. Without this
            // an OOM mid-loop would leak every previously simplified
            // argument's child trees.
            var filled: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < filled) : (i += 1) freeCalcValueInner(allocator, &new_args[i]);
                allocator.free(new_args);
            }
            while (filled < fc.args.len) : (filled += 1) {
                const simplified = try simplify(allocator, &fc.args[filled]);
                new_args[filled] = simplified.*;
                allocator.destroy(@as(*CalcValue, @constCast(simplified)));
            }
            const node = try allocator.create(CalcValue);
            node.* = .{ .function_call = .{
                .name = fc.name,
                .args = new_args,
            } };
            return node;
        },
        else => unreachable,
    }
}

fn isGeneratedUnitDescription(unit: []const u8) bool {
    return std.mem.findAny(u8, unit, "*/^()") != null;
}

fn unitFactorCanAttachDirectly(unit: []const u8) bool {
    const trimmed = std.mem.trim(u8, unit, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "%")) return true;

    var i: usize = 0;
    if (trimmed[i] == '-') {
        i += 1;
        if (i >= trimmed.len) return false;
    }
    if (!(std.ascii.isAlphabetic(trimmed[i]) or trimmed[i] == '_')) return false;
    i += 1;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (!(std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

fn parseGeneratedUnitFactors(
    allocator: Allocator,
    unit: []const u8,
    numerators: *std.ArrayList([]const u8),
    denominators: *std.ArrayList([]const u8),
) !bool {
    const trimmed = std.mem.trim(u8, unit, " \t\n\r");
    if (trimmed.len == 0) return true;

    if (std.mem.endsWith(u8, trimmed, "^-1")) {
        const base = trimmed[0 .. trimmed.len - 3];
        const inner = if (base.len >= 2 and base[0] == '(' and base[base.len - 1] == ')')
            base[1 .. base.len - 1]
        else
            base;
        var it = std.mem.splitScalar(u8, inner, '*');
        while (it.next()) |part| {
            const factor = std.mem.trim(u8, part, " \t\n\r");
            if (factor.len == 0) return false;
            try denominators.append(allocator, factor);
        }
        return true;
    }

    if (std.mem.findScalar(u8, trimmed, '/')) |slash_idx| {
        const left = trimmed[0..slash_idx];
        const right_raw = trimmed[slash_idx + 1 ..];
        const right = if (right_raw.len >= 2 and right_raw[0] == '(' and right_raw[right_raw.len - 1] == ')')
            right_raw[1 .. right_raw.len - 1]
        else
            right_raw;

        var left_it = std.mem.splitScalar(u8, left, '*');
        while (left_it.next()) |part| {
            const factor = std.mem.trim(u8, part, " \t\n\r");
            if (factor.len == 0) return false;
            try numerators.append(allocator, factor);
        }

        var right_it = std.mem.splitScalar(u8, right, '*');
        while (right_it.next()) |part| {
            const factor = std.mem.trim(u8, part, " \t\n\r");
            if (factor.len == 0) return false;
            try denominators.append(allocator, factor);
        }
        return true;
    }

    var it = std.mem.splitScalar(u8, trimmed, '*');
    while (it.next()) |part| {
        const factor = std.mem.trim(u8, part, " \t\n\r");
        if (factor.len == 0) return false;
        try numerators.append(allocator, factor);
    }
    return true;
}

fn appendParsedUnitFactors(
    allocator: Allocator,
    unit: ?[]const u8,
    numerators: *std.ArrayList([]const u8),
    denominators: *std.ArrayList([]const u8),
) !bool {
    if (unit) |u| {
        if (isGeneratedUnitDescription(u)) {
            return parseGeneratedUnitFactors(allocator, u, numerators, denominators);
        }
        try numerators.append(allocator, u);
    }
    return true;
}

/// Describe a combined unit string. The boolean `owned` lets the caller
/// know whether the returned slice was freshly allocated (must be freed
/// when the surrounding `CalcValue.number` is destroyed) or is a
/// borrowed view of one of the input numerators (must NOT be freed).
const DescribedUnit = struct { unit: ?[]const u8, owned: bool };

fn describeCombinedUnit(allocator: Allocator, numerators: []const []const u8, denominators: []const []const u8) !DescribedUnit {
    if (numerators.len == 0 and denominators.len == 0) return .{ .unit = null, .owned = false };
    if (denominators.len == 0) {
        // A single bare numerator (`px`, `em`, ...) flows through as a
        // borrowed view; duping a plain unit here would leak it on every
        // fold (see ChatGPT-Pro F-11) and the borrowed slice's lifetime
        // is the surrounding `CalcValue` tree, which always outlives any
        // ephemeral simplify scratch.
        if (numerators.len == 1) return .{ .unit = numerators[0], .owned = false };
        return .{ .unit = @as([]const u8, try std.mem.join(allocator, "*", numerators)), .owned = true };
    }
    if (numerators.len == 0) {
        const joined = try std.mem.join(allocator, "*", denominators);
        defer allocator.free(joined);
        if (denominators.len == 1) return .{ .unit = @as([]const u8, try std.mem.concat(allocator, u8, &.{ joined, "^-1" })), .owned = true };
        return .{ .unit = @as([]const u8, try std.mem.concat(allocator, u8, &.{ "(", joined, ")^-1" })), .owned = true };
    }

    const joined_num = try std.mem.join(allocator, "*", numerators);
    defer allocator.free(joined_num);
    const joined_den = try std.mem.join(allocator, "*", denominators);
    defer allocator.free(joined_den);
    if (denominators.len == 1) {
        return .{ .unit = @as([]const u8, try std.mem.concat(allocator, u8, &.{ joined_num, "/", joined_den })), .owned = true };
    }
    return .{ .unit = @as([]const u8, try std.mem.concat(allocator, u8, &.{ joined_num, "/(", joined_den, ")" })), .owned = true };
}

const CombineResult = struct {
    unit: ?[]const u8,
    unit_owned: bool,
    factor: f64,
};

fn combineUnits(allocator: Allocator, left: ?[]const u8, right: ?[]const u8, op: Operator) !CombineResult {
    var numerators: std.ArrayList([]const u8) = .empty;
    defer numerators.deinit(allocator);
    var denominators: std.ArrayList([]const u8) = .empty;
    defer denominators.deinit(allocator);
    if (!(try appendParsedUnitFactors(allocator, left, &numerators, &denominators))) return .{ .unit = null, .unit_owned = false, .factor = 1.0 };

    var right_nums: std.ArrayList([]const u8) = .empty;
    defer right_nums.deinit(allocator);
    var right_dens: std.ArrayList([]const u8) = .empty;
    defer right_dens.deinit(allocator);
    if (!(try appendParsedUnitFactors(allocator, right, &right_nums, &right_dens))) return .{ .unit = null, .unit_owned = false, .factor = 1.0 };

    switch (op) {
        .multiply => {
            try numerators.appendSlice(allocator, right_nums.items);
            try denominators.appendSlice(allocator, right_dens.items);
        },
        .divide => {
            try numerators.appendSlice(allocator, right_dens.items);
            try denominators.appendSlice(allocator, right_nums.items);
        },
        else => {
            // add/subtract fall back to whichever side carries a unit
            // (the caller has already proven the two sides match or are
            // compatible). Borrow the source slice instead of duping; the
            // caller will mark `unit_owned = false` so the borrowed view
            // is not freed when the resulting node is destroyed.
            const u = if (left != null) left else right;
            return .{ .unit = u, .unit_owned = false, .factor = 1.0 };
        },
    }

    // Unit cancellation: first exact matches, then compatible matches
    var factor: f64 = 1.0;
    var i: usize = 0;
    while (i < numerators.items.len) {
        const numerator = numerators.items[i];
        var j: usize = 0;
        var removed = false;
        // Try exact match first
        while (j < denominators.items.len) : (j += 1) {
            if (std.mem.eql(u8, numerator, denominators.items[j])) {
                _ = numerators.orderedRemove(i);
                _ = denominators.orderedRemove(j);
                removed = true;
                break;
            }
        }
        if (!removed) {
            // Try compatible unit match (e.g., px/in, s/ms)
            const num_canonical = toCanonicalUnit(1.0, numerator);
            const num_family = if (num_canonical != null) unitFamily(numerator) else null;
            if (num_family) |nf| {
                j = 0;
                while (j < denominators.items.len) : (j += 1) {
                    const den_family = unitFamily(denominators.items[j]);
                    if (den_family) |df| {
                        if (nf == df) {
                            const den_canonical = toCanonicalUnit(1.0, denominators.items[j]);
                            if (den_canonical) |dc| {
                                factor *= num_canonical.? / dc;
                                _ = numerators.orderedRemove(i);
                                _ = denominators.orderedRemove(j);
                                removed = true;
                                break;
                            }
                        }
                    }
                }
            }
        }
        if (!removed) i += 1;
    }

    const described = try describeCombinedUnit(allocator, numerators.items, denominators.items);
    return .{ .unit = described.unit, .unit_owned = described.owned, .factor = factor };
}

fn convertCompatibleUnit(value: f64, from: ?[]const u8, to: ?[]const u8) ?f64 {
    if (from == null or to == null) return null;
    if (std.mem.eql(u8, from.?, to.?)) return value;
    const canonical = toCanonicalUnit(value, from.?) orelse return null;
    return fromCanonicalUnit(canonical, to.?);
}

const UnitFamily = enum { length, angle, time, frequency, resolution };

fn unitFamily(unit: []const u8) ?UnitFamily {
    if (std.mem.eql(u8, unit, "px") or std.mem.eql(u8, unit, "in") or
        std.mem.eql(u8, unit, "cm") or std.mem.eql(u8, unit, "mm") or
        std.mem.eql(u8, unit, "pt") or std.mem.eql(u8, unit, "pc") or
        std.mem.eql(u8, unit, "Q") or std.mem.eql(u8, unit, "q"))
        return .length;
    if (std.mem.eql(u8, unit, "deg") or std.mem.eql(u8, unit, "rad") or
        std.mem.eql(u8, unit, "grad") or std.mem.eql(u8, unit, "turn"))
        return .angle;
    if (std.mem.eql(u8, unit, "s") or std.mem.eql(u8, unit, "ms"))
        return .time;
    if (std.mem.eql(u8, unit, "Hz") or std.mem.eql(u8, unit, "kHz"))
        return .frequency;
    if (std.mem.eql(u8, unit, "dppx") or std.mem.eql(u8, unit, "dpi") or
        std.mem.eql(u8, unit, "dpcm"))
        return .resolution;
    return null;
}

// ---------------------------------------------------------------------------
// Public API - toCss
// ---------------------------------------------------------------------------

pub fn toCss(allocator: Allocator, value: *const CalcValue) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try writeCss(&buf, allocator, value, null, false);
    return try buf.toOwnedSlice(allocator);
}

fn writeCss(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    value: *const CalcValue,
    parent_op: ?Operator,
    is_right_child: bool,
) !void {
    if (value.* == .number) {
        const n = value.number;
        const special_with_unit = n.unit != null and (std.math.isNan(n.value) or std.math.isInf(n.value));
        const needs_special_divide_parens = special_with_unit and parent_op == .divide and is_right_child;
        if (needs_special_divide_parens) try buf.append(allocator, '(');
        if (n.unit) |u| {
            if (isGeneratedUnitDescription(u)) {
                // Format generated units as calc()-compatible CSS:
                // e.g., value=1, unit="px*rad/(ms*Hz)"  ->  "1px * 1rad / 1ms / 1Hz"
                var numerators: std.ArrayList([]const u8) = .empty;
                defer numerators.deinit(allocator);
                var denominators: std.ArrayList([]const u8) = .empty;
                defer denominators.deinit(allocator);
                if (try parseGeneratedUnitFactors(allocator, u, &numerators, &denominators)) {
                    try writeNumber(buf, allocator, n.value);
                    if (numerators.items.len > 0) {
                        if (std.math.isNan(n.value) or std.math.isInf(n.value)) {
                            try buf.appendSlice(allocator, " * 1");
                            try buf.appendSlice(allocator, numerators.items[0]);
                        } else {
                            try buf.appendSlice(allocator, numerators.items[0]);
                        }
                        for (numerators.items[1..]) |factor| {
                            try buf.appendSlice(allocator, " * 1");
                            try buf.appendSlice(allocator, factor);
                        }
                    }
                    for (denominators.items) |factor| {
                        try buf.appendSlice(allocator, " / 1");
                        try buf.appendSlice(allocator, factor);
                    }
                } else {
                    try writeNumber(buf, allocator, n.value);
                    try buf.appendSlice(allocator, u);
                }
            } else {
                try writeNumber(buf, allocator, n.value);
                if (std.math.isNan(n.value) or std.math.isInf(n.value)) {
                    if (unitFactorCanAttachDirectly(u)) {
                        try buf.appendSlice(allocator, " * 1");
                    } else {
                        try buf.appendSlice(allocator, " * ");
                    }
                    try buf.appendSlice(allocator, u);
                } else {
                    try buf.appendSlice(allocator, u);
                }
            }
        } else {
            try writeNumber(buf, allocator, n.value);
        }
        if (needs_special_divide_parens) try buf.append(allocator, ')');
        return;
    }

    switch (value.*) {
        .variable => |name| {
            try buf.appendSlice(allocator, name);
        },
        .operation => |op| {
            const need_parens = blk: {
                if (parent_op) |pop| {
                    if (pop.precedence() > op.op.precedence()) break :blk true;
                    if (is_right_child) {
                        if (pop == .subtract and op.op.precedence() == pop.precedence()) break :blk true;
                        if (pop == .divide and op.op.precedence() == pop.precedence()) break :blk true;
                    }
                }
                break :blk false;
            };

            if (need_parens) try buf.append(allocator, '(');
            try writeCss(buf, allocator, op.left, op.op, false);
            try buf.append(allocator, ' ');
            var emitted_op = op.op;
            var rhs_abs_override: ?struct { value: f64, unit: ?[]const u8 } = null;
            if (op.right.* == .number) {
                const rn = op.right.number;
                if (std.math.signbit(rn.value) and rn.value != 0 and !std.math.isNan(rn.value)) {
                    if (op.op == .add) {
                        emitted_op = .subtract;
                        rhs_abs_override = .{ .value = @abs(rn.value), .unit = rn.unit };
                    } else if (op.op == .subtract) {
                        emitted_op = .add;
                        rhs_abs_override = .{ .value = @abs(rn.value), .unit = rn.unit };
                    }
                }
            }
            try buf.appendSlice(allocator, emitted_op.symbol());
            try buf.append(allocator, ' ');
            if (rhs_abs_override) |rhs_num| {
                var rhs_node = CalcValue{ .number = .{ .value = rhs_num.value, .unit = rhs_num.unit } };
                try writeCss(buf, allocator, &rhs_node, emitted_op, true);
            } else {
                try writeCss(buf, allocator, op.right, emitted_op, true);
            }
            if (need_parens) try buf.append(allocator, ')');
        },
        .function_call => |fc| {
            try buf.appendSlice(allocator, fc.name);
            try buf.append(allocator, '(');
            for (fc.args, 0..) |*arg, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try writeCss(buf, allocator, arg, null, false);
            }
            try buf.append(allocator, ')');
        },
        else => unreachable,
    }
}

fn writeNumber(buf: *std.ArrayList(u8), allocator: Allocator, value: f64) !void {
    if (std.math.isNan(value)) {
        try buf.appendSlice(allocator, "NaN");
        return;
    }
    if (std.math.isInf(value)) {
        try buf.appendSlice(allocator, if (value < 0) "-infinity" else "infinity");
        return;
    }

    // Format the number: avoid unnecessary decimal places for integers.
    if (value == @floor(value) and @abs(value) < 1e15) {
        const ival: i64 = @trunc(value);
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{ival}) catch return;
        try buf.appendSlice(allocator, s);
    } else {
        var tmp: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.10}", .{value}) catch return;
        var len = s.len;
        if (std.mem.findScalar(u8, s, '.')) |dot_idx| {
            while (len > dot_idx + 1 and s[len - 1] == '0') len -= 1;
            if (len == dot_idx + 1) len = dot_idx;
        }
        const result = s[0..len];
        if (std.mem.eql(u8, result, "-0")) {
            try buf.appendSlice(allocator, "0");
        } else if (std.mem.startsWith(u8, result, "-.")) {
            try buf.appendSlice(allocator, "-0");
            try buf.appendSlice(allocator, result[1..]);
        } else if (std.mem.startsWith(u8, result, ".")) {
            try buf.appendSlice(allocator, "0");
            try buf.appendSlice(allocator, result);
        } else {
            try buf.appendSlice(allocator, result);
        }
    }
}

// ---------------------------------------------------------------------------
// Public API - freeCalcValue
// ---------------------------------------------------------------------------

pub fn freeCalcValue(allocator: Allocator, value: *CalcValue) void {
    freeCalcValueInner(allocator, value);
}

fn freeCalcValueInner(allocator: Allocator, value: *const CalcValue) void {
    if (value.* == .number) {
        const n = value.number;
        // Only owned units (created via dupe / join / concat inside
        // simplify or combineUnits) are freed here. Borrowed units --
        // pointing back at the original parser source or transferred to
        // another node by `takeNumberUnit` -- are owned by something
        // else and must not be touched here.
        if (n.unit_owned) {
            if (n.unit) |unit| allocator.free(unit);
        }
        return;
    }
    switch (value.*) {
        .variable => {},
        .operation => |op| {
            freeCalcValueInner(allocator, op.left);
            allocator.destroy(@as(*CalcValue, @constCast(op.left)));
            freeCalcValueInner(allocator, op.right);
            allocator.destroy(@as(*CalcValue, @constCast(op.right)));
        },
        .function_call => |fc| {
            for (fc.args) |*arg| {
                freeCalcValueInner(allocator, arg);
            }
            allocator.free(fc.args);
        },
        else => unreachable,
    }
}

// ===========================================================================
// Tests
// ===========================================================================

fn destroyCalcValue(allocator: Allocator, val: *const CalcValue) void {
    const v: *CalcValue = @constCast(val);
    freeCalcValue(allocator, v);
    allocator.destroy(v);
}

test "parse simple expression: 10px + 20px" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "10px + 20px");
    defer destroyCalcValue(allocator, val);
    // Should be an add operation.
    switch (val.*) {
        .operation => |op| {
            try testing.expectEqual(Operator.add, op.op);
            if (op.left.* == .number) {
                const n = op.left.number;
                try testing.expectApproxEqAbs(10.0, n.value, 0.001);
                try testing.expectEqualStrings("px", n.unit.?);
            } else return error.TestUnexpectedResult;
            if (op.right.* == .number) {
                const n = op.right.number;
                try testing.expectApproxEqAbs(20.0, n.value, 0.001);
                try testing.expectEqualStrings("px", n.unit.?);
            } else return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse with precedence: 10px + 2 * 5px" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "10px + 2 * 5px");
    defer destroyCalcValue(allocator, val);
    // Top-level should be add: 10px + (2 * 5px)
    switch (val.*) {
        .operation => |op| {
            try testing.expectEqual(Operator.add, op.op);
            // Right side should be multiply
            switch (op.right.*) {
                .operation => |mul| {
                    try testing.expectEqual(Operator.multiply, mul.op);
                    if (mul.left.* == .number) {
                        const n = mul.left.number;
                        try testing.expectApproxEqAbs(2.0, n.value, 0.001);
                    } else return error.TestUnexpectedResult;
                    if (mul.right.* == .number) {
                        const n = mul.right.number;
                        try testing.expectApproxEqAbs(5.0, n.value, 0.001);
                        try testing.expectEqualStrings("px", n.unit.?);
                    } else return error.TestUnexpectedResult;
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse rejects malformed decimal point" {
    const allocator = testing.allocator;
    try testing.expectError(error.UnexpectedToken, parseCalc(allocator, "."));
}

test "parse nested: calc(100% - calc(20px + 10px))" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "calc(100% - calc(20px + 10px))");
    defer destroyCalcValue(allocator, val);
    // Should be: 100% - (20px + 10px)
    switch (val.*) {
        .operation => |op| {
            try testing.expectEqual(Operator.subtract, op.op);
            if (op.left.* == .number) {
                const n = op.left.number;
                try testing.expectApproxEqAbs(100.0, n.value, 0.001);
                try testing.expectEqualStrings("%", n.unit.?);
            } else return error.TestUnexpectedResult;
            switch (op.right.*) {
                .operation => |inner| {
                    try testing.expectEqual(Operator.add, inner.op);
                },
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse min/max/clamp: min(100px, 50%)" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "min(100px, 50%)");
    defer destroyCalcValue(allocator, val);
    switch (val.*) {
        .function_call => |fc| {
            try testing.expectEqualStrings("min", fc.name);
            try testing.expectEqual(@as(usize, 2), fc.args.len);
            if (fc.args[0] == .number) {
                const n = fc.args[0].number;
                try testing.expectApproxEqAbs(100.0, n.value, 0.001);
                try testing.expectEqualStrings("px", n.unit.?);
            } else return error.TestUnexpectedResult;
            if (fc.args[1] == .number) {
                const n = fc.args[1].number;
                try testing.expectApproxEqAbs(50.0, n.value, 0.001);
                try testing.expectEqualStrings("%", n.unit.?);
            } else return error.TestUnexpectedResult;
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse clamp: clamp(100px, 50%, 500px)" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "clamp(100px, 50%, 500px)");
    defer destroyCalcValue(allocator, val);
    switch (val.*) {
        .function_call => |fc| {
            try testing.expectEqualStrings("clamp", fc.name);
            try testing.expectEqual(@as(usize, 3), fc.args.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "simplify same-unit addition: 10px + 20px = 30px" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "10px + 20px");
    defer destroyCalcValue(allocator, val);
    const simplified = try simplify(allocator, val);
    defer destroyCalcValue(allocator, simplified);
    if (simplified.* == .number) {
        const n = simplified.number;
        try testing.expectApproxEqAbs(30.0, n.value, 0.001);
        try testing.expectEqualStrings("px", n.unit.?);
    } else return error.TestUnexpectedResult;
}

test "simplify multiplication by number: 2 * 10px = 20px" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "2 * 10px");
    defer destroyCalcValue(allocator, val);
    const simplified = try simplify(allocator, val);
    defer destroyCalcValue(allocator, simplified);
    if (simplified.* == .number) {
        const n = simplified.number;
        try testing.expectApproxEqAbs(20.0, n.value, 0.001);
        try testing.expectEqualStrings("px", n.unit.?);
    } else return error.TestUnexpectedResult;
}

test "preserve different-unit expressions: 100% - 20px" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "100% - 20px");
    defer destroyCalcValue(allocator, val);
    const simplified = try simplify(allocator, val);
    defer destroyCalcValue(allocator, simplified);
    // Should remain an operation (not foldable).
    switch (simplified.*) {
        .operation => |op| {
            try testing.expectEqual(Operator.subtract, op.op);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "simplify keeps different-unit zero addition in calc" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "100% - 0px");
    defer destroyCalcValue(allocator, val);
    const simplified = try simplify(allocator, val);
    defer destroyCalcValue(allocator, simplified);
    switch (simplified.*) {
        .operation => |op| try testing.expectEqual(Operator.subtract, op.op),
        else => return error.TestUnexpectedResult,
    }
}

test "toCss output formatting" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "100% - 20px");
    defer destroyCalcValue(allocator, val);
    const css = try toCss(allocator, val);
    defer allocator.free(css);
    try testing.expectEqualStrings("100% - 20px", css);
}

test "toCss min function" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "min(10px, 5vw)");
    defer destroyCalcValue(allocator, val);
    const css = try toCss(allocator, val);
    defer allocator.free(css);
    try testing.expectEqualStrings("min(10px, 5vw)", css);
}

test "toCss clamp function" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "clamp(100px, 50%, 500px)");
    defer destroyCalcValue(allocator, val);
    const css = try toCss(allocator, val);
    defer allocator.free(css);
    try testing.expectEqualStrings("clamp(100px, 50%, 500px)", css);
}

test "parse number without unit" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "42");
    defer destroyCalcValue(allocator, val);
    if (val.* == .number) {
        const n = val.number;
        try testing.expectApproxEqAbs(42.0, n.value, 0.001);
        try testing.expect(n.unit == null);
    } else return error.TestUnexpectedResult;
}

test "parse fractional number: 1.5rem" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "1.5rem");
    defer destroyCalcValue(allocator, val);
    if (val.* == .number) {
        const n = val.number;
        try testing.expectApproxEqAbs(1.5, n.value, 0.001);
        try testing.expectEqualStrings("rem", n.unit.?);
    } else return error.TestUnexpectedResult;
}

test "simplify division by unitless: 100px / 2 = 50px" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "100px / 2");
    defer destroyCalcValue(allocator, val);
    const simplified = try simplify(allocator, val);
    defer destroyCalcValue(allocator, simplified);
    if (simplified.* == .number) {
        const n = simplified.number;
        try testing.expectApproxEqAbs(50.0, n.value, 0.001);
        try testing.expectEqualStrings("px", n.unit.?);
    } else return error.TestUnexpectedResult;
}

test "simplify compatible-unit addition keeps left unit" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "1in + 96px");
    defer destroyCalcValue(allocator, val);
    const simplified = try simplify(allocator, val);
    defer destroyCalcValue(allocator, simplified);
    if (simplified.* == .number) {
        const n = simplified.number;
        try testing.expectApproxEqAbs(2.0, n.value, 0.001);
        try testing.expectEqualStrings("in", n.unit.?);
    } else return error.TestUnexpectedResult;
}

test "simplify compatible-unit division cancels units" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "96px / 1in");
    defer destroyCalcValue(allocator, val);
    const simplified = try simplify(allocator, val);
    defer destroyCalcValue(allocator, simplified);
    if (simplified.* == .number) {
        const n = simplified.number;
        try testing.expectApproxEqAbs(1.0, n.value, 0.001);
        try testing.expect(n.unit == null);
    } else return error.TestUnexpectedResult;
}

test "toCss with precedence parenthesization" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "2 * (10px + 5px)");
    defer destroyCalcValue(allocator, val);
    const css = try toCss(allocator, val);
    defer allocator.free(css);
    try testing.expectEqualStrings("2 * (10px + 5px)", css);
}

test "toCss preserves right-side subtraction grouping" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "1 - (2 + 3)");
    defer destroyCalcValue(allocator, val);
    const css = try toCss(allocator, val);
    defer allocator.free(css);
    try testing.expectEqualStrings("1 - (2 + 3)", css);
}

test "toCss preserves right-side division grouping" {
    const allocator = testing.allocator;
    const val = try parseCalc(allocator, "1 / (2 * 3)");
    defer destroyCalcValue(allocator, val);
    const css = try toCss(allocator, val);
    defer allocator.free(css);
    try testing.expectEqualStrings("1 / (2 * 3)", css);
}
