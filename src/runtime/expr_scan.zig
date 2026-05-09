// ============================================================================
// Character-classification helpers (canonical definitions live here)
// ============================================================================

/// Returns true if `c` is a valid CSS identifier start character.
pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        c == '_' or c == '-' or c >= 0x80;
}

/// Returns true if `c` is a valid CSS identifier character.
pub fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        c == '_' or c == '-' or (c >= '0' and c <= '9') or c >= 0x80;
}

/// Returns true if the character at `index` in `text` is preceded by an odd
/// number of backslashes (i.e. it is CSS-escaped).
pub fn isEscapedCharacter(text: []const u8, index: usize) bool {
    if (index == 0) return false;
    var backslashes: usize = 0;
    var i = index;
    while (i > 0) {
        i -= 1;
        if (text[i] != '\\') break;
        backslashes += 1;
    }
    return (backslashes % 2) == 1;
}

/// Returns true if `c` is an ASCII hexadecimal digit.
pub fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn leadingUnitlessNumberDoubleHyphenSplit(text: []const u8) ?usize {
    if (text.len < 4) return null;

    var i: usize = 0;
    var saw_digit = false;
    while (i < text.len and isDigit(text[i])) : (i += 1) {
        saw_digit = true;
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and isDigit(text[i])) : (i += 1) {
            saw_digit = true;
        }
    }
    if (!saw_digit) return null;
    if (i + 2 >= text.len) return null;
    if (text[i] != '-' or text[i + 1] != '-') return null;
    if (!isIdentChar(text[i + 2])) return null;
    return i;
}
pub fn tokenStartsWithDoubleHyphenIdentifier(text: []const u8) bool {
    if (text.len >= 2 and text[0] == '-' and text[1] == '-') return true;
    return leadingUnitlessNumberDoubleHyphenSplit(text) != null;
}
