// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Writing I-JSON (RFC 7493) in the JCS form (RFC 8785). Callers emit object
//! members in sorted key order themselves (every key the tool writes is
//! ASCII, so UTF-16 order is byte order); this file gets strings and numbers
//! exactly right.

const std = @import("std");
const Writer = std.Io.Writer;

/// RFC 8785 section 3.2.2.2: escape `"` `\` and controls; \b \t \n \f \r
/// short forms; other controls as lowercase \u00xx; everything else literal.
pub fn string(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0x08 => try w.writeAll("\\b"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        0x0c => try w.writeAll("\\f"),
        '\r' => try w.writeAll("\\r"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// An integer inside I-JSON's exact range (|n| < 2^53).
pub fn int(w: *Writer, n: i64) Writer.Error!void {
    std.debug.assert(@abs(n) < (1 << 53));
    try w.print("{d}", .{n});
}

/// A finite number in [1e-6, 1e21) or zero, as ECMAScript prints it:
/// shortest round-trip digits, plain decimal notation. The tool only writes
/// share fractions, so the exponent forms are refused rather than guessed.
pub fn fraction(w: *Writer, x: f64) Writer.Error!void {
    std.debug.assert(std.math.isFinite(x));
    if (x == 0) return w.writeAll("0");
    std.debug.assert(@abs(x) >= 1e-6 and @abs(x) < 1e21);
    try w.print("{d}", .{x});
}

test "JCS strings and numbers" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try string(&w, "a\"b\\c\n\x01é€");
    try w.writeByte(' ');
    try fraction(&w, 0.4);
    try w.writeByte(' ');
    try fraction(&w, 1.0 / 3.0);
    try w.writeByte(' ');
    try fraction(&w, 1);
    try w.writeByte(' ');
    try fraction(&w, 0.000001);
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\u0001é€\" 0.4 0.3333333333333333 1 0.000001", w.buffered());
}
