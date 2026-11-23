// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! The live board as one static HTML page (tier 3).
//!
//! Pure: `work-queue/board/v1` JSON bytes in, HTML bytes out. No clock, no
//! file, no store. The page is derived from the same JSON that
//! `q board --json` prints, so the two views cannot disagree, and the page is
//! a function of its input (equal JSON gives equal bytes).
//!
//! Rules this file keeps:
//!   * Every job-supplied string (title, owner, id, category, line) reaches
//!     the page only as escaped text content inside `<bdi>`. None is ever put
//!     in an attribute, a style, a class or an id; class names come from the
//!     State enum and ids from constants.
//!   * No script and no remote reference. A Content-Security-Policy meta
//!     (`default-src 'none'`) backs that up: if escaping were ever wrong,
//!     the browser still would not run injected script.
//!   * State is never shown by colour alone: every card carries its state as
//!     a word, every meter carries its numbers and an over/under word, every
//!     warning tile carries a word.
//!   * Colours are data (`tones`), the CSS is written from them, and a test
//!     checks WCAG contrast of every text pair, in both themes.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Options = struct {
    /// `<meta http-equiv="refresh">` interval. Null: no refresh (a one-shot page).
    refresh_seconds: ?u32 = null,
};

pub const Error = error{ BadBoard, OutOfMemory, WriteFailed };

// ---------------------------------------------------------------- the input

const State = enum { queued, ready, admitted, running, checkpoint, held, completed, dropped };

const Category = struct { name: []const u8, share_target: f64, share_used: f64 };
const Host = struct { cap: u32, heavy_running: u32, hold: bool, reserved: u32, slots: u32, workers: u32 };
const Lease = struct { expires_at: []const u8, worker: []const u8 };
const Job = struct {
    category: []const u8,
    id: []const u8,
    lease: ?Lease,
    line: []const u8,
    measured: bool,
    owner: []const u8,
    priority: u32,
    reason: []const u8,
    rejects: u32,
    res: u32,
    state: State,
    title: []const u8,
};
const Board = struct {
    categories: []const Category,
    generated_at: []const u8,
    host: Host,
    jobs: []const Job,
    schema: []const u8,
};

const schema_name = "work-queue/board/v1";
const line_prefixes = [_][]const u8{ "Waiting: ", "Held by: ", "Progress: " };

/// The seven columns of TIERS.adoc, in flow order. `dropped` is not a column:
/// those jobs are listed in a closed `<details>` under the board, so no job
/// is silently missing from the page.
const columns = [_]struct { state: State, title: []const u8, note: []const u8 }{
    .{ .state = .queued, .title = "Queued", .note = "captured, incomplete record" },
    .{ .state = .ready, .title = "Ready", .note = "record complete, awaiting admission" },
    .{ .state = .admitted, .title = "Admitted", .note = "reservation held, not yet started" },
    .{ .state = .running, .title = "Running", .note = "lease held by one worker" },
    .{ .state = .checkpoint, .title = "Checkpoint", .note = "evidence under review" },
    .{ .state = .held, .title = "Held", .note = "deliberately stopped" },
    .{ .state = .completed, .title = "Completed", .note = "finished jobs" },
};

// ------------------------------------------------------------------ colours

/// A named colour in both themes. The names are the CSS custom properties.
pub const Tone = struct { name: []const u8, light: u24, dark: u24 };

pub const tones = [_]Tone{
    .{ .name = "bg", .light = 0xf6f5f1, .dark = 0x17171a },
    .{ .name = "panel", .light = 0xffffff, .dark = 0x222226 },
    .{ .name = "ink", .light = 0x1d1d1b, .dark = 0xecebe6 },
    .{ .name = "muted", .light = 0x5c5b57, .dark = 0xa8a8a2 },
    .{ .name = "line", .light = 0xdcdad3, .dark = 0x38383e },
    .{ .name = "meter-bg", .light = 0xe6e4dd, .dark = 0x2e2e34 },
    .{ .name = "meter", .light = 0x2a64a3, .dark = 0x6aa6e8 },
    .{ .name = "warn", .light = 0xa82f28, .dark = 0xff8a82 },
    .{ .name = "queued", .light = 0x76766f, .dark = 0x9a9a94 },
    .{ .name = "ready", .light = 0x2a64a3, .dark = 0x6aa6e8 },
    .{ .name = "admitted", .light = 0x7a4fb5, .dark = 0xb394e8 },
    .{ .name = "running", .light = 0x1b7a50, .dark = 0x42c08a },
    .{ .name = "checkpoint", .light = 0xa86a0a, .dark = 0xe4a43a },
    .{ .name = "held", .light = 0xb3362f, .dark = 0xff8a82 },
    .{ .name = "completed", .light = 0x4b4b48, .dark = 0xa8a8a2 },
    .{ .name = "dropped", .light = 0x6a6a66, .dark = 0x8c8c86 },
};

fn writeTones(w: *Writer, dark: bool) Writer.Error!void {
    for (tones) |t| try w.print("--{s}:#{x:0>6};", .{ t.name, if (dark) t.dark else t.light });
}

// ---------------------------------------------------------------------- css

const css_body =
    \\*{box-sizing:border-box}
    \\body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;padding:16px}
    \\h1{font-size:22px;margin:0 0 4px}
    \\h2{font-size:15px;margin:0 0 8px}
    \\h3{font-size:14px;margin:0 0 8px;display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap}
    \\h3 small{color:var(--muted);font-weight:400;font-size:12px}
    \\h4{font-size:14px;margin:0 0 2px}
    \\.sub{color:var(--muted);margin:0 0 16px;font-size:14px}
    \\p,ul{margin:0;padding:0}
    \\ul{list-style:none}
    \\section{margin-bottom:16px}
    \\bdi,.wrap{overflow-wrap:anywhere}
    \\.strip{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px}
    \\.tile{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
    \\.tile b{display:block;font-size:13px;color:var(--muted);font-weight:500}
    \\.tile span{font-size:18px}
    \\.tile.warn{border-color:var(--warn)}
    \\.tile.warn span{color:var(--warn);font-weight:700}
    \\.shares{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
    \\.shares .note{color:var(--muted);font-size:13px;margin:0 0 8px}
    \\.share{display:grid;grid-template-columns:minmax(0,170px) 1fr minmax(0,210px);gap:8px;align-items:center;font-size:14px;margin:6px 0}
    \\.bar{display:block;width:100%;height:10px;background:var(--meter-bg);border-radius:5px;overflow:hidden}
    \\.bar .fill{fill:var(--meter)}
    \\.bar .tick{stroke:var(--ink);stroke-width:3px;vector-effect:non-scaling-stroke}
    \\.board{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:10px}
    \\.col{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:8px;min-height:120px}
    \\.none{color:var(--muted);font-size:13px}
    \\.card{border:1px solid var(--line);border-left:6px solid var(--c);border-radius:6px;padding:8px;margin-bottom:8px;font-size:14px}
    \\.card .m{color:var(--muted);font-size:13px}
    \\.card .why{margin-top:6px;padding:4px 6px;border-radius:4px;background:var(--meter-bg);font-size:13px}
    \\.tag{display:inline-block;font-size:12px;padding:1px 6px;border-radius:10px;border:1px solid var(--muted);margin:0 4px 2px 0}
    \\.tag.st{font-weight:700;color:var(--ink);border-color:var(--c)}
    \\.queued{--c:var(--queued)}.ready{--c:var(--ready)}.admitted{--c:var(--admitted)}.running{--c:var(--running)}
    \\.checkpoint{--c:var(--checkpoint)}.held{--c:var(--held)}.completed{--c:var(--completed)}.dropped{--c:var(--dropped)}
    \\.col.dropped{margin-top:10px;min-height:0}
    \\summary{cursor:pointer;font-weight:600}
    \\details ul{margin-top:8px}
    \\footer{margin-top:16px;font-size:13px;color:var(--muted)}
    \\@media (max-width:560px){
    \\body{padding:12px}
    \\.share{grid-template-columns:1fr;gap:2px}
    \\.board{grid-template-columns:1fr}
    \\}
    \\
;

// ------------------------------------------------------------------- escape

/// U+200E/200F marks, U+202A..202E embeddings and overrides, U+2066..2069 isolates.
fn isBidiControl(cp: u21) bool {
    return cp == 0x200e or cp == 0x200f or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069);
}

/// Write `s` as HTML text content. Escapes & < > " ' ; control characters
/// (other than tab and newline) and invalid UTF-8 become U+FFFD. Nothing
/// else is changed, so hostile input stays visible as text and inert.
fn esc(w: *Writer, s: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            '\t', '\n' => try w.writeByte(c),
            0...0x08, 0x0b...0x1f, 0x7f => try w.writeAll("\u{fffd}"),
            // printable ASCII except & " ' < > (handled above)
            0x20, 0x21, 0x23...0x25, 0x28...0x3b, 0x3d, 0x3f...0x7e => try w.writeByte(c),
            else => {
                const n = std.unicode.utf8ByteSequenceLength(c) catch {
                    try w.writeAll("\u{fffd}");
                    i += 1;
                    continue;
                };
                if (i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch unreachable;
                    // Bidi formatting controls are invisible and reorder text
                    // around them; show them as U+FFFD instead.
                    if (isBidiControl(cp)) try w.writeAll("\u{fffd}") else try w.writeAll(s[i .. i + n]);
                    i += n;
                } else {
                    try w.writeAll("\u{fffd}");
                    i += 1;
                }
                continue;
            },
        }
        i += 1;
    }
}

/// Job-supplied text: escaped, and isolated for bidirectional text so a
/// right-to-left override in a title cannot reorder the rest of the line.
fn bdi(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeAll("<bdi>");
    try esc(w, s);
    try w.writeAll("</bdi>");
}

// ------------------------------------------------------------------- render

fn percent(x: f64) u32 {
    const p = @round(std.math.clamp(x, 0, 1) * 100);
    return @intFromFloat(p);
}

fn lessJob(_: void, a: Job, b: Job) bool {
    if (a.priority != b.priority) return a.priority < b.priority;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn card(w: *Writer, j: Job) Writer.Error!void {
    try w.print("<li class=\"card {t}\">\n", .{j.state});
    try w.writeAll("<h4>");
    try bdi(w, j.title);
    try w.print("</h4>\n<p class=\"m\"><span class=\"tag st\">{t}</span><span class=\"tag\">", .{j.state});
    try bdi(w, j.category);
    try w.print("</span><span class=\"tag\">P{d}</span> ", .{j.priority});
    try bdi(w, j.owner);
    try w.writeAll(" &middot; ");
    try bdi(w, j.id);
    try w.writeAll("</p>\n");
    try w.print("<p class=\"m\">needs {d} GiB, {s}", .{ j.res, if (j.measured) "measured" else "estimate" });
    if (j.rejects > 0) try w.print(", rejected {d}&times;", .{j.rejects});
    if (j.lease) |l| {
        try w.writeAll("; lease ");
        try bdi(w, l.worker);
        try w.writeAll(" until ");
        try bdi(w, l.expires_at);
    }
    try w.writeAll("</p>\n<p class=\"why\">");
    try bdi(w, j.line);
    try w.writeAll("</p>\n</li>\n");
}

fn tile(w: *Writer, warn: bool, label: []const u8, comptime fmt: []const u8, args: anytype) Writer.Error!void {
    try w.print("<div class=\"tile{s}\"><b>{s}</b><span>", .{ if (warn) " warn" else "", label });
    try w.print(fmt, args);
    try w.writeAll("</span></div>\n");
}

fn validate(b: Board) Error!void {
    if (!std.mem.eql(u8, b.schema, schema_name)) return error.BadBoard;
    for (b.jobs) |j| {
        // Rule R2: a job that cannot say Waiting / Held by / Progress is a
        // board bug, and the page refuses to hide it.
        var ok = false;
        for (line_prefixes) |p| ok = ok or std.mem.startsWith(u8, j.line, p);
        if (!ok) return error.BadBoard;
        if ((j.state == .running) != (j.lease != null)) return error.BadBoard;
    }
}

/// Render the page for `board_json` (the bytes `q board --json` writes).
/// `arena` holds the parse and may be freed by the caller afterwards.
pub fn render(arena: std.mem.Allocator, board_json: []const u8, opts: Options, w: *Writer) Error!void {
    const b = std.json.parseFromSliceLeaky(Board, arena, board_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadBoard,
    };
    try validate(b);
    const sorted = try arena.dupe(Job, b.jobs);
    std.mem.sort(Job, sorted, {}, lessJob);

    var running: u32 = 0;
    for (sorted) |j| {
        if (j.state == .running) running += 1;
    }
    const h = b.host;
    const free = if (h.cap > h.reserved) h.cap - h.reserved else 0;

    // The whole stylesheet is built first so the CSP can name it by hash:
    // no 'unsafe-inline', and no style attribute anywhere on the page.
    var style: Writer.Allocating = .init(arena);
    try style.writer.writeAll("\n:root{");
    try writeTones(&style.writer, false);
    try style.writer.writeAll("}\n@media (prefers-color-scheme: dark){:root{");
    try writeTones(&style.writer, true);
    try style.writer.writeAll("}}\n");
    try style.writer.writeAll(css_body);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(style.written(), &digest, .{});
    var b64: [std.base64.standard.Encoder.calcSize(digest.len)]u8 = undefined;
    const hash = std.base64.standard.Encoder.encode(&b64, &digest);

    try w.writeAll("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    try w.writeAll("<meta name=\"color-scheme\" content=\"light dark\">\n");
    try w.print("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'sha256-{s}'; base-uri 'none'; form-action 'none'\">\n", .{hash});
    if (opts.refresh_seconds) |s| try w.print("<meta http-equiv=\"refresh\" content=\"{d}\">\n", .{s});
    try w.writeAll("<title>Work Queue Board</title>\n<style>");
    try w.writeAll(style.written());
    try w.writeAll("</style>\n</head>\n<body>\n<header>\n<h1>Work Queue Board</h1>\n<p class=\"sub\">Read-only view, generated ");
    try bdi(w, b.generated_at);
    try w.writeAll(" from <span class=\"wrap\">" ++ schema_name ++ "</span>. Run <code>q board</code> for the text form.</p>\n</header>\n<main>\n");

    // headroom strip
    try w.writeAll("<section aria-labelledby=\"h-head\">\n<h2 id=\"h-head\">Host headroom</h2>\n<div class=\"strip\">\n");
    try tile(w, free == 0, "Unreserved", "{d} GiB{s}", .{ free, if (free == 0) " (NONE FREE)" else "" });
    try tile(w, false, "Reserved", "{d} of {d} GiB", .{ h.reserved, h.cap });
    const full = h.slots > 0 and h.heavy_running >= h.slots;
    try tile(w, full, "Heavy slots", "{d} of {d} in use{s}", .{ h.heavy_running, h.slots, if (full) " (FULL)" else "" });
    try tile(w, false, "Workers", "{d} running of {d}", .{ running, h.workers });
    try tile(w, h.hold, "Host hold", "{s}", .{if (h.hold) "ON (no job is admitted)" else "off"});
    try w.writeAll("</div>\n</section>\n");

    // category shares
    try w.writeAll("<section aria-labelledby=\"h-shares\">\n<div class=\"shares\">\n<h2 id=\"h-shares\">Category shares</h2>\n");
    try w.writeAll("<p class=\"note\">Bar = share of the reservation held now; tick = target. Equal priorities go to the category furthest below its target.</p>\n");
    try w.writeAll("<ul>\n");
    for (b.categories) |c| {
        const used = percent(c.share_used);
        const target = percent(c.share_target);
        const word = if (used > target) "over target" else if (used < target) "under target" else "on target";
        try w.writeAll("<li class=\"share\"><span class=\"wrap\">");
        try bdi(w, c.name);
        try w.print("</span><svg class=\"bar\" viewBox=\"0 0 100 10\" preserveAspectRatio=\"none\" aria-hidden=\"true\" focusable=\"false\"><rect class=\"fill\" width=\"{d}\" height=\"10\"/><line class=\"tick\" x1=\"{d}\" x2=\"{d}\" y1=\"0\" y2=\"10\"/></svg><span>{d}% of {d}%, {s}</span></li>\n", .{ used, target, target, used, target, word });
    }
    try w.writeAll("</ul>\n</div>\n</section>\n");

    // the seven state columns
    try w.writeAll("<section aria-labelledby=\"h-jobs\">\n<h2 id=\"h-jobs\">Jobs by state</h2>\n<div class=\"board\">\n");
    inline for (columns) |col| {
        var n: usize = 0;
        for (sorted) |j| {
            if (j.state == col.state) n += 1;
        }
        try w.print("<section class=\"col {t}\" aria-labelledby=\"c-{t}\">\n<h3 id=\"c-{t}\"><span>{s} ({d})</span><small>{s}</small></h3>\n", .{ col.state, col.state, col.state, col.title, n, col.note });
        if (n == 0) {
            try w.writeAll("<p class=\"none\">No jobs in this state.</p>\n");
        } else {
            try w.writeAll("<ul>\n");
            for (sorted) |j| {
                if (j.state == col.state) try card(w, j);
            }
            try w.writeAll("</ul>\n");
        }
        try w.writeAll("</section>\n");
    }
    try w.writeAll("</div>\n");

    // dropped jobs: not a column, but never hidden (an h3 under "Jobs by state")
    var dropped: usize = 0;
    for (sorted) |j| {
        if (j.state == .dropped) dropped += 1;
    }
    if (dropped > 0) {
        try w.print("<section class=\"col dropped\" aria-labelledby=\"c-dropped\">\n<h3 id=\"c-dropped\"><span>Dropped ({d})</span><small>removed from the queue</small></h3>\n<details>\n<summary>Show dropped jobs</summary>\n<ul>\n", .{dropped});
        for (sorted) |j| {
            if (j.state == .dropped) try card(w, j);
        }
        try w.writeAll("</ul>\n</details>\n</section>\n");
    }
    try w.writeAll("</section>\n");

    try w.writeAll("</main>\n<footer>Every card shows one line beginning &ldquo;Waiting:&rdquo;, &ldquo;Held by:&rdquo; or &ldquo;Progress:&rdquo;. If a job cannot produce that line, the board has a bug, not the job.</footer>\n</body>\n</html>\n");
}

// -------------------------------------------------------------------- tests

fn channel(v: u24, shift: u5) f64 {
    const c: f64 = @as(f64, @floatFromInt((v >> shift) & 0xff)) / 255.0;
    return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}

fn luminance(v: u24) f64 {
    return 0.2126 * channel(v, 16) + 0.7152 * channel(v, 8) + 0.0722 * channel(v, 0);
}

/// WCAG 2.x contrast ratio, 1..21.
pub fn contrast(a: u24, b: u24) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "WCAG contrast ratio matches the published extremes" {
    try std.testing.expectApproxEqAbs(21.0, contrast(0x000000, 0xffffff), 0.001);
    try std.testing.expectApproxEqAbs(1.0, contrast(0x777777, 0x777777), 0.001);
}

test "every text pair meets WCAG AA (4.5) and every state edge meets 3, in both themes" {
    // [foreground, background]: text actually drawn on that background.
    const text = [_][2][]const u8{
        .{ "ink", "bg" },     .{ "ink", "panel" },   .{ "ink", "meter-bg" },
        .{ "muted", "bg" },   .{ "muted", "panel" }, .{ "muted", "meter-bg" },
        .{ "warn", "panel" },
    };
    // Non-text marks that carry meaning, against the panel they sit on (WCAG 1.4.11).
    const marks = [_][2][]const u8{
        .{ "meter", "meter-bg" },   .{ "ink", "meter-bg" },
        .{ "queued", "panel" },     .{ "ready", "panel" },
        .{ "admitted", "panel" },   .{ "running", "panel" },
        .{ "checkpoint", "panel" }, .{ "held", "panel" },
        .{ "completed", "panel" },  .{ "dropped", "panel" },
        .{ "warn", "panel" },
    };
    const find = struct {
        fn f(name: []const u8) Tone {
            for (tones) |t| if (std.mem.eql(u8, t.name, name)) return t;
            unreachable;
        }
    }.f;
    var worst_text: f64 = 99;
    var worst_mark: f64 = 99;
    for ([_]bool{ false, true }) |dark| {
        for (text) |p| {
            const a = find(p[0]);
            const b = find(p[1]);
            const r = contrast(if (dark) a.dark else a.light, if (dark) b.dark else b.light);
            worst_text = @min(worst_text, r);
            if (r < 4.5) {
                std.debug.print("text {s} on {s} ({s}): {d:.2} < 4.5\n", .{ p[0], p[1], if (dark) "dark" else "light", r });
                return error.TestUnexpectedResult;
            }
        }
        for (marks) |p| {
            const a = find(p[0]);
            const b = find(p[1]);
            const r = contrast(if (dark) a.dark else a.light, if (dark) b.dark else b.light);
            worst_mark = @min(worst_mark, r);
            if (r < 3.0) {
                std.debug.print("mark {s} on {s} ({s}): {d:.2} < 3\n", .{ p[0], p[1], if (dark) "dark" else "light", r });
                return error.TestUnexpectedResult;
            }
        }
    }
    std.debug.print("contrast: worst text {d:.2}:1, worst mark {d:.2}:1\n", .{ worst_text, worst_mark });
}

fn renderToString(a: std.mem.Allocator, json: []const u8, opts: Options) Error![]u8 {
    var out: Writer.Allocating = .init(a);
    try render(a, json, opts, &out.writer);
    return out.written();
}

test "hostile strings are escaped and never reach an attribute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hostile = "<script>alert(1)</script>\\\"'&amp; \\u0000\\u202e";
    const json = "{\"categories\":[{\"name\":\"" ++ hostile ++ "\",\"share_target\":0.5,\"share_used\":0}]," ++
        "\"generated_at\":\"2026-11-18T10:00:00Z\",\"host\":{\"cap\":4,\"heavy_running\":0,\"hold\":false,\"reserved\":0,\"slots\":1,\"workers\":2}," ++
        "\"jobs\":[{\"category\":\"" ++ hostile ++ "\",\"id\":\"" ++ hostile ++ "\",\"lease\":null,\"line\":\"Waiting: " ++ hostile ++ "\"," ++
        "\"measured\":false,\"owner\":\"" ++ hostile ++ "\",\"priority\":1,\"reason\":\"none\",\"rejects\":0,\"res\":1,\"state\":\"ready\",\"title\":\"" ++ hostile ++ "\"}]," ++
        "\"schema\":\"work-queue/board/v1\"}";
    const html = try renderToString(a, json, .{});
    try std.testing.expect(std.mem.indexOf(u8, html, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;alert(1)&lt;/script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&amp;amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&#39;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\u{fffd}") != null); // NUL replaced
    try std.testing.expect(std.mem.indexOf(u8, html, "\u{202e}") == null); // bidi override replaced
    try std.testing.expect(std.mem.indexOf(u8, html, "refresh") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "unsafe-inline") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, " style=") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "style-src 'sha256-") != null);
}

test "refresh meta only when asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"categories\":[],\"generated_at\":\"2026-11-18T10:00:00Z\",\"host\":{\"cap\":4,\"heavy_running\":0,\"hold\":false,\"reserved\":0,\"slots\":1,\"workers\":2},\"jobs\":[],\"schema\":\"work-queue/board/v1\"}";
    const html = try renderToString(a, json, .{ .refresh_seconds = 10 });
    try std.testing.expect(std.mem.indexOf(u8, html, "<meta http-equiv=\"refresh\" content=\"10\">") != null);
}

test "bad boards are refused, not rendered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = "{\"categories\":[],\"generated_at\":\"x\",\"host\":{\"cap\":4,\"heavy_running\":0,\"hold\":false,\"reserved\":0,\"slots\":1,\"workers\":2},\"jobs\":[%J%],\"schema\":\"%S%\"}";
    const bad_schema = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, base, "%J%", ""), "%S%", "work-queue/board/v2");
    try std.testing.expectError(error.BadBoard, renderToString(a, bad_schema, .{}));
    try std.testing.expectError(error.BadBoard, renderToString(a, "not json", .{}));
    const job = "{\"category\":\"c\",\"id\":\"i\",\"lease\":null,\"line\":\"Whatever\",\"measured\":false,\"owner\":\"o\",\"priority\":1,\"reason\":\"none\",\"rejects\":0,\"res\":1,\"state\":\"ready\",\"title\":\"t\"}";
    const no_prefix = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, base, "%J%", job), "%S%", schema_name);
    try std.testing.expectError(error.BadBoard, renderToString(a, no_prefix, .{}));
}
