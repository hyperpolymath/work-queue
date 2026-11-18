// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! A small TOML subset, enough for job and host records, that refuses
//! anything outside it with a line number rather than guessing:
//! comments, `[table]` headers (one level), bare keys, basic and literal
//! strings, integers, floats, booleans, arrays (may span lines) and inline
//! tables. Duplicate keys are an error. No dates, no dotted keys, no
//! multi-line strings, no arrays of tables.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
    table: Table,
};

pub const Entry = struct { key: []const u8, value: Value };

pub const Table = struct {
    entries: []const Entry,

    pub fn get(t: Table, key: []const u8) ?Value {
        for (t.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }
};

pub const Error = error{ Syntax, DuplicateKey, OutOfMemory };

pub const Diagnostic = struct { line: usize = 0, msg: []const u8 = "" };

const Parser = struct {
    src: []const u8,
    i: usize = 0,
    line: usize = 1,
    arena: std.mem.Allocator,
    diag: *Diagnostic,

    fn fail(p: *Parser, msg: []const u8) Error {
        p.diag.* = .{ .line = p.line, .msg = msg };
        return error.Syntax;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    /// Skip spaces and tabs, and a comment if one starts here.
    fn skipInline(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t') {
                p.i += 1;
            } else if (c == '#') {
                while (p.peek()) |d| {
                    if (d == '\n') break;
                    p.i += 1;
                }
            } else break;
        }
    }

    /// Skip whitespace, newlines and comments (inside arrays, between lines).
    fn skipAll(p: *Parser) void {
        while (true) {
            p.skipInline();
            const c = p.peek() orelse return;
            if (c == '\n') {
                p.line += 1;
                p.i += 1;
            } else if (c == '\r' and p.i + 1 < p.src.len and p.src[p.i + 1] == '\n') {
                p.i += 1;
            } else return;
        }
    }

    fn endOfLine(p: *Parser) Error!void {
        p.skipInline();
        const c = p.peek() orelse return;
        if (c == '\r') p.i += 1;
        if (p.peek() != @as(?u8, '\n')) return p.fail("expected end of line");
    }

    fn key(p: *Parser) Error![]const u8 {
        const s = p.i;
        while (p.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') p.i += 1 else break;
        }
        if (p.i == s) return p.fail("expected a bare key");
        return p.src[s..p.i];
    }

    fn string(p: *Parser) Error![]const u8 {
        const q = p.src[p.i];
        p.i += 1;
        if (p.i + 1 < p.src.len and p.src[p.i] == q and p.src[p.i + 1] == q) return p.fail("multi-line strings are not supported");
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated string");
            p.i += 1;
            if (c == q) break;
            if (c == '\n') return p.fail("unterminated string");
            if (c == '\\' and q == '"') {
                const e = p.peek() orelse return p.fail("unterminated escape");
                p.i += 1;
                switch (e) {
                    '"' => try out.append(p.arena, '"'),
                    '\\' => try out.append(p.arena, '\\'),
                    'n' => try out.append(p.arena, '\n'),
                    't' => try out.append(p.arena, '\t'),
                    'r' => try out.append(p.arena, '\r'),
                    'u' => {
                        if (p.i + 4 > p.src.len) return p.fail("short \\u escape");
                        const cp = std.fmt.parseInt(u21, p.src[p.i .. p.i + 4], 16) catch return p.fail("bad \\u escape");
                        p.i += 4;
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail("bad \\u code point");
                        try out.appendSlice(p.arena, buf[0..n]);
                    },
                    else => return p.fail("unsupported escape"),
                }
            } else try out.append(p.arena, c);
        }
        if (!std.unicode.utf8ValidateSlice(out.items)) return p.fail("string is not valid UTF-8");
        return out.items;
    }

    fn value(p: *Parser) Error!Value {
        const c = p.peek() orelse return p.fail("expected a value");
        switch (c) {
            '"', '\'' => return .{ .string = try p.string() },
            '[' => {
                p.i += 1;
                var xs: std.ArrayList(Value) = .empty;
                while (true) {
                    p.skipAll();
                    if (p.peek() == @as(?u8, ']')) break;
                    try xs.append(p.arena, try p.value());
                    p.skipAll();
                    if (p.peek() == @as(?u8, ',')) {
                        p.i += 1;
                    } else if (p.peek() != @as(?u8, ']')) return p.fail("expected , or ] in array");
                }
                p.i += 1;
                return .{ .array = xs.items };
            },
            '{' => {
                p.i += 1;
                var es: std.ArrayList(Entry) = .empty;
                p.skipInline();
                if (p.peek() == @as(?u8, '}')) {
                    p.i += 1;
                    return .{ .table = .{ .entries = es.items } };
                }
                while (true) {
                    p.skipInline();
                    try p.pair(&es);
                    p.skipInline();
                    const d = p.peek() orelse return p.fail("unterminated inline table");
                    p.i += 1;
                    if (d == '}') break;
                    if (d != ',') return p.fail("expected , or } in inline table");
                }
                return .{ .table = .{ .entries = es.items } };
            },
            else => {
                const s = p.i;
                while (p.peek()) |d| {
                    if (std.ascii.isAlphanumeric(d) or d == '_' or d == '+' or d == '-' or d == '.') p.i += 1 else break;
                }
                const tok = p.src[s..p.i];
                if (tok.len == 0) return p.fail("expected a value");
                if (std.mem.eql(u8, tok, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, tok, "false")) return .{ .boolean = false };
                var clean: std.ArrayList(u8) = .empty;
                for (tok) |d| if (d != '_') try clean.append(p.arena, d);
                if (std.fmt.parseInt(i64, clean.items, 10)) |n| {
                    return .{ .int = n };
                } else |_| {}
                if (std.mem.indexOfAny(u8, clean.items, ".eE") != null) {
                    if (std.fmt.parseFloat(f64, clean.items)) |f| {
                        if (std.math.isFinite(f)) return .{ .float = f };
                    } else |_| {}
                }
                return p.fail("unsupported value (dates and bare words are outside the subset)");
            },
        }
    }

    fn pair(p: *Parser, es: *std.ArrayList(Entry)) Error!void {
        const k = try p.key();
        p.skipInline();
        if (p.peek() == @as(?u8, '.')) return p.fail("dotted keys are not supported");
        if (p.peek() != @as(?u8, '=')) return p.fail("expected =");
        p.i += 1;
        p.skipInline();
        const v = try p.value();
        for (es.items) |e| if (std.mem.eql(u8, e.key, k)) {
            p.diag.* = .{ .line = p.line, .msg = "duplicate key" };
            return error.DuplicateKey;
        };
        try es.append(p.arena, .{ .key = k, .value = v });
    }
};

/// Parse a document into a table. Every allocation goes to `arena`.
pub fn parse(arena: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!Table {
    var p = Parser{ .src = src, .arena = arena, .diag = diag };
    var root: std.ArrayList(Entry) = .empty;
    var cur: *std.ArrayList(Entry) = &root;
    var tables: std.ArrayList(struct { name: []const u8, es: *std.ArrayList(Entry) }) = .empty;
    while (true) {
        p.skipAll();
        const c = p.peek() orelse break;
        if (c == '[') {
            p.i += 1;
            if (p.peek() == @as(?u8, '[')) return p.fail("arrays of tables are not supported");
            p.skipInline();
            const name = try p.key();
            p.skipInline();
            if (p.peek() != @as(?u8, ']')) return p.fail("expected ] after table name (one level only)");
            p.i += 1;
            try p.endOfLine();
            for (root.items) |e| if (std.mem.eql(u8, e.key, name)) return p.fail("table name repeats a key");
            for (tables.items) |t| if (std.mem.eql(u8, t.name, name)) return p.fail("table defined twice");
            const es = try arena.create(std.ArrayList(Entry));
            es.* = .empty;
            try tables.append(arena, .{ .name = name, .es = es });
            cur = es;
        } else {
            try p.pair(cur);
            try p.endOfLine();
        }
    }
    for (tables.items) |t| {
        for (root.items) |e| if (std.mem.eql(u8, e.key, t.name)) return p.fail("table name repeats a key");
        try root.append(arena, .{ .key = t.name, .value = .{ .table = .{ .entries = t.es.items } } });
    }
    return .{ .entries = root.items };
}

test "the job record of CONTRACT section 2 parses" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var d: Diagnostic = .{};
    const t = try parse(a.allocator(),
        \\id          = "2026-11-16-proven-abi-batch"
        \\priority    = 1                    # 1 urgent .. 4 whenever
        \\repos       = ["hyperpolymath/proven#237",
        \\               'x']
        \\[admission]
        \\resources   = { ram_gib = 6, cpu = 4, cash = 0.00, measured = false }
        \\duration    = "40m"
        \\
    , &d);
    try std.testing.expectEqualStrings("2026-11-16-proven-abi-batch", t.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 1), t.get("priority").?.int);
    try std.testing.expectEqual(@as(usize, 2), t.get("repos").?.array.len);
    const r = t.get("admission").?.table.get("resources").?.table;
    try std.testing.expectEqual(@as(i64, 6), r.get("ram_gib").?.int);
    try std.testing.expectEqual(false, r.get("measured").?.boolean);
}

test "outside the subset is refused with a line number" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.Syntax, parse(a.allocator(), "a = 1\nb = 2026-11-16\n", &d));
    try std.testing.expectEqual(@as(usize, 2), d.line);
    try std.testing.expectError(error.DuplicateKey, parse(a.allocator(), "a = 1\na = 2\n", &d));
    try std.testing.expectError(error.Syntax, parse(a.allocator(), "a.b = 1\n", &d));
}
