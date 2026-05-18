/// Per-call source-syntax override shared across the parse / resolve / VM
/// layers. The CLI's `--indented` / `--no-indented` / `--scss` /
/// `--plain-css` flags push a non-null value here for the duration of one
/// compile; null means "infer from the entry path" (the official Sass CLI default:
/// `.sass` -> indented, `.css` -> plain CSS, otherwise SCSS).
///
/// The override lives in this small standalone module so that both
/// `ir/compiler.zig` (which decides indented vs SCSS at the lexer / parser
/// boundary) and `resolve/resolver.zig` (which decides plain-CSS vs SCSS
/// when seeding the entry module) can read it without introducing a
/// cross-layer import.
pub const SyntaxOverride = enum { scss, sass, css };

threadlocal var override_tls: ?SyntaxOverride = null;

pub fn set(value: ?SyntaxOverride) void {
    override_tls = value;
}

pub fn get() ?SyntaxOverride {
    return override_tls;
}
