// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! `q`: the imperative shell around the work-queue core.
//!
//! Store ($WQ_HOME, default $XDG_STATE_HOME/work-queue):
//!   events.jsonl        append-only event log, I-JSON in JCS form, one per line
//!   jobs/<id>/<rev>.toml  immutable job revisions
//!   host/<rev>.toml       immutable host revisions
//! Every write holds an exclusive flock on events.jsonl for read, check and
//! append. Exit codes: 0 done, 3 refused (guard named on stderr), 2 usage,
//! 1 internal error (including a log that does not replay).
//!
//! WQ_NOW (RFC 3339, UTC) overrides the clock, for tests.

const std = @import("std");
const core = @import("queue");
const toml = @import("toml.zig");
const time = @import("time.zig");
const jcs = @import("jcs.zig");
const ledger = @import("ledger.zig");

const Io = std.Io;
const Writer = Io.Writer;
const Ledger = ledger.Ledger;
const Kind = ledger.Kind;
const Event = ledger.Event;

const Exit = enum(u8) { done = 0, internal = 1, usage = 2, refused = 3 };

const Fail = error{ Usage, Refused, Internal };

const Ctx = struct {
    io: Io,
    arena: std.mem.Allocator,
    home: []const u8,
    now: i64,
    out: *Writer,
    err: *Writer,

    fn path(c: *Ctx, parts: []const []const u8) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(c.arena, c.home);
        try all.appendSlice(c.arena, parts);
        return std.fs.path.join(c.arena, all.items);
    }

    fn usage(c: *Ctx, comptime fmt: []const u8, args: anytype) Fail {
        c.err.print("q: " ++ fmt ++ "\n", args) catch {};
        return error.Usage;
    }

    fn refuse(c: *Ctx, comptime fmt: []const u8, args: anytype) Fail {
        c.err.print("q: refused: " ++ fmt ++ "\n", args) catch {};
        return error.Refused;
    }

    fn internal(c: *Ctx, comptime fmt: []const u8, args: anytype) Fail {
        c.err.print("q: internal error: " ++ fmt ++ "\n", args) catch {};
        return error.Internal;
    }
};

// ------------------------------------------------------------- records I/O

fn readFile(c: *Ctx, p: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(c.io, p, c.arena, .limited(1 << 20));
}

fn parseToml(c: *Ctx, what: []const u8, src: []const u8) Fail!toml.Table {
    var d: toml.Diagnostic = .{};
    return toml.parse(c.arena, src, &d) catch |e| switch (e) {
        error.OutOfMemory => c.internal("out of memory", .{}),
        else => c.usage("{s}: line {d}: {s}", .{ what, d.line, d.msg }),
    };
}

fn jobFromSource(c: *Ctx, what: []const u8, src: []const u8, rev: u32) Fail!ledger.JobRev {
    const t = try parseToml(c, what, src);
    var p: ledger.Problem = .{};
    return ledger.parseJob(c.arena, t, rev, &p) catch |e| switch (e) {
        error.OutOfMemory => c.internal("out of memory", .{}),
        error.BadRecord => c.usage("{s}: bad or unknown key: {s}", .{ what, p.msg }),
    };
}

fn hostFromSource(c: *Ctx, what: []const u8, src: []const u8, rev: u32) Fail!ledger.Host {
    const t = try parseToml(c, what, src);
    var p: ledger.Problem = .{};
    return ledger.parseHost(c.arena, t, rev, &p) catch |e| switch (e) {
        error.OutOfMemory => c.internal("out of memory", .{}),
        error.BadRecord => c.usage("{s}: bad, missing or unknown key: {s}", .{ what, p.msg }),
    };
}

fn revName(c: *Ctx, rev: u32) ![]const u8 {
    return std.fmt.allocPrint(c.arena, "{d}.toml", .{rev});
}

/// Write an immutable revision. If a crash left the same bytes there before
/// the event was appended, that is the same revision; different bytes are not.
fn writeRevision(c: *Ctx, dir: []const u8, name: []const u8, bytes: []const u8) Fail!void {
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(c.io, dir) catch |e| return c.internal("cannot create {s}: {t}", .{ dir, e });
    const p = std.fs.path.join(c.arena, &.{ dir, name }) catch return c.internal("out of memory", .{});
    const f = cwd.createFile(c.io, p, .{ .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => {
            const old = readFile(c, p) catch |e2| return c.internal("cannot read {s}: {t}", .{ p, e2 });
            if (std.mem.eql(u8, old, bytes)) return;
            return c.internal("{s} exists with other content; revisions are immutable", .{p});
        },
        else => return c.internal("cannot create {s}: {t}", .{ p, e }),
    };
    defer f.close(c.io);
    f.writeStreamingAll(c.io, bytes) catch |e| return c.internal("cannot write {s}: {t}", .{ p, e });
    f.sync(c.io) catch |e| return c.internal("cannot sync {s}: {t}", .{ p, e });
}

// ----------------------------------------------------------------- events

fn eventLine(c: *Ctx, ev: Event) ![]const u8 {
    var aw: Writer.Allocating = .init(c.arena);
    const w = &aw.writer;
    // JCS: members in sorted key order: action, at, job, rev, seq, worker.
    try w.writeAll("{\"action\":");
    try jcs.string(w, @tagName(ev.kind));
    try w.writeAll(",\"at\":");
    try jcs.string(w, &time.format(ev.at));
    if (!ev.kind.isHostEvent()) {
        try w.writeAll(",\"job\":");
        try jcs.string(w, ev.job);
    }
    if (ev.kind != .host_hold and ev.kind != .host_release) {
        try w.writeAll(",\"rev\":");
        try jcs.int(w, ev.rev);
    }
    try w.writeAll(",\"seq\":");
    try jcs.int(w, @intCast(ev.seq));
    if (ev.kind == .start) {
        try w.writeAll(",\"worker\":");
        try jcs.string(w, ev.worker);
    }
    try w.writeAll("}\n");
    return aw.written();
}

fn parseEvent(c: *Ctx, line: []const u8, n: usize) Fail!Event {
    const v = std.json.parseFromSliceLeaky(std.json.Value, c.arena, line, .{}) catch
        return c.internal("events.jsonl line {d} is not JSON", .{n});
    if (v != .object) return c.internal("events.jsonl line {d} is not an object", .{n});
    const o = v.object;
    const s = struct {
        fn get(m: std.json.ObjectMap, k: []const u8) ?[]const u8 {
            const x = m.get(k) orelse return null;
            return if (x == .string) x.string else null;
        }
        fn int(m: std.json.ObjectMap, k: []const u8) ?i64 {
            const x = m.get(k) orelse return null;
            return if (x == .integer) x.integer else null;
        }
    };
    const kind = std.meta.stringToEnum(Kind, s.get(o, "action") orelse "") orelse
        return c.internal("events.jsonl line {d}: unknown action", .{n});
    const at = time.parse(s.get(o, "at") orelse "") catch return c.internal("events.jsonl line {d}: bad at", .{n});
    const seq = s.int(o, "seq") orelse return c.internal("events.jsonl line {d}: no seq", .{n});
    const rev = s.int(o, "rev") orelse 0;
    if (seq < 1 or rev < 0 or rev > std.math.maxInt(u32)) return c.internal("events.jsonl line {d}: bad seq or rev", .{n});
    return .{
        .kind = kind,
        .at = at,
        .seq = @intCast(seq),
        .job = s.get(o, "job") orelse "",
        .rev = @intCast(rev),
        .worker = s.get(o, "worker") orelse "",
    };
}

/// Fold the whole log. Any event a guard refuses means the log is corrupt.
fn replay(c: *Ctx, l: *Ledger, log: []const u8) Fail!void {
    var it = std.mem.splitScalar(u8, log, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (line.len == 0) {
            if (it.peek() == null) break;
            return c.internal("events.jsonl line {d} is empty", .{n});
        }
        const ev = try parseEvent(c, line, n);
        var hr: ?ledger.Host = null;
        var jr: ?ledger.JobRev = null;
        switch (ev.kind) {
            .host_amend => {
                const p = c.path(&.{ "host", revName(c, ev.rev) catch unreachable }) catch unreachable;
                const src = readFile(c, p) catch |e| return c.internal("cannot read {s}: {t}", .{ p, e });
                hr = hostFromSource(c, p, src, ev.rev) catch return c.internal("{s} no longer parses", .{p});
            },
            .add, .amend => {
                if (!ledger.validId(ev.job)) return c.internal("events.jsonl line {d}: bad job id", .{n});
                const p = c.path(&.{ "jobs", ev.job, revName(c, ev.rev) catch unreachable }) catch unreachable;
                const src = readFile(c, p) catch |e| return c.internal("cannot read {s}: {t}", .{ p, e });
                jr = jobFromSource(c, p, src, ev.rev) catch return c.internal("{s} no longer parses", .{p});
            },
            else => {},
        }
        const r = l.apply(ev, hr, jr) catch return c.internal("out of memory", .{});
        if (r) |why| return c.internal("events.jsonl line {d} (seq {d}, {t}) does not replay: {s}", .{ n, ev.seq, ev.kind, why.words });
    }
}

const Session = struct {
    file: ?Io.File,
    len: u64,
    l: Ledger,
};

fn open(c: *Ctx, write: bool) Fail!Session {
    const p = c.path(&.{"events.jsonl"}) catch return c.internal("out of memory", .{});
    const cwd = Io.Dir.cwd();
    var f: Io.File = undefined;
    if (write) {
        cwd.createDirPath(c.io, c.home) catch |e| return c.internal("cannot create {s}: {t}", .{ c.home, e });
        f = cwd.createFile(c.io, p, .{ .read = true, .truncate = false, .lock = .exclusive }) catch |e|
            return c.internal("cannot open {s}: {t}", .{ p, e });
    } else {
        f = cwd.openFile(c.io, p, .{ .lock = .shared }) catch |e| switch (e) {
            error.FileNotFound => return .{ .file = null, .len = 0, .l = .{ .arena = c.arena } },
            else => return c.internal("cannot open {s}: {t}", .{ p, e }),
        };
    }
    const len = f.length(c.io) catch |e| return c.internal("cannot stat {s}: {t}", .{ p, e });
    const buf = c.arena.alloc(u8, len) catch return c.internal("out of memory", .{});
    const got = f.readPositionalAll(c.io, buf, 0) catch |e| return c.internal("cannot read {s}: {t}", .{ p, e });
    if (got != len) return c.internal("short read of {s}", .{p});
    if (len > 0 and buf[len - 1] != '\n') return c.internal("{s} does not end in a newline (a torn append?)", .{p});
    var s = Session{ .file = f, .len = len, .l = .{ .arena = c.arena } };
    try replay(c, &s.l, buf);
    return s;
}

fn close(c: *Ctx, s: *Session) void {
    if (s.file) |f| f.close(c.io); // closing releases the flock
}

/// Check an event against the ledger, then append it. Refusals exit 3.
fn commit(c: *Ctx, s: *Session, ev0: Event, hr: ?ledger.Host, jr: ?ledger.JobRev) Fail!void {
    var ev = ev0;
    ev.seq = s.l.seq + 1;
    ev.at = c.now;
    const r = s.l.apply(ev, hr, jr) catch return c.internal("out of memory", .{});
    if (r) |why| return c.refuse("{s}", .{why.words});
    const line = eventLine(c, ev) catch return c.internal("out of memory", .{});
    const f = s.file.?;
    f.writePositionalAll(c.io, line, s.len) catch |e| return c.internal("cannot append to events.jsonl: {t}", .{e});
    f.sync(c.io) catch |e| return c.internal("cannot sync events.jsonl: {t}", .{e});
    s.len += line.len;
    c.out.print("{d} {t}{s}{s}\n", .{ ev.seq, ev.kind, if (ev.job.len > 0) " " else "", ev.job }) catch {};
}

/// Append one lease_lapse for every running job whose lease has expired.
fn tick(c: *Ctx, s: *Session) Fail!void {
    for (s.l.jobs.items, 0..) |j, i| {
        if (j.st == .running and c.now >= s.l.lease_until.items[i]) {
            try commit(c, s, .{ .kind = .lease_lapse, .at = c.now, .seq = 0, .job = s.l.ids.items[i], .rev = s.l.revs.items[i].rev }, null, null);
        }
    }
}

// ------------------------------------------------------------------ board

fn reasonWords(r: core.Reason) []const u8 {
    return switch (r) {
        .none => "none",
        .no_record => "no record",
        .gate => "gate",
        .awaiting_start => "awaiting start",
        .validating => "validating",
        .lease_expired => "lease expired",
        .held_by_owner => "held by owner",
        .preempted => "preempted",
        .reject_limit => "reject limit",
    };
}

fn workerName(c: *Ctx, w: u32) []const u8 {
    return std.fmt.allocPrint(c.arena, "w{d}", .{w + 1}) catch "w?";
}

/// Rule R2: every job says why it waits, who holds it, or how it is going.
fn statusLine(c: *Ctx, l: *const Ledger, i: usize) ![]const u8 {
    const j = l.jobs.items[i];
    const r = l.revs.items[i];
    const a = c.arena;
    return switch (j.st) {
        .queued => if (r.missing) |m|
            std.fmt.allocPrint(a, "Waiting: admission record incomplete: {s}", .{m})
        else
            a.dupe(u8, "Waiting: admission record complete; q record makes it ready"),
        .ready => switch (core.transition(l.view(), l.decl.items, l.host.?.params, .{ .tag = .admit, .job = @intCast(i) })) {
            .refused => |g| std.fmt.allocPrint(a, "Waiting: {s}", .{g.words()}),
            .ok => a.dupe(u8, "Waiting: the gate is open; q admit admits it"),
        },
        .admitted => a.dupe(u8, "Waiting: admitted, awaiting start on a worker"),
        .running => blk: {
            const left = l.lease_until.items[i] - c.now;
            break :blk if (left > 0)
                std.fmt.allocPrint(a, "Progress: running on {s}, lease {d}m left", .{ workerName(c, j.lease), @divFloor(left + 59, 60) })
            else
                std.fmt.allocPrint(a, "Progress: running on {s}, lease expired; the next q tick lapses it", .{workerName(c, j.lease)});
        },
        .checkpoint => a.dupe(u8, "Waiting: checkpoint taken, awaiting q accept or q reject"),
        .held => switch (j.reason) {
            .lease_expired => a.dupe(u8, "Held by: lease expired; q release returns it to the gate"),
            .reject_limit => a.dupe(u8, "Held by: reject limit; needs an owner edit"),
            else => a.dupe(u8, "Held by: owner; q release returns it to the gate"),
        },
        .completed => a.dupe(u8, "Progress: completed"),
        .dropped => a.dupe(u8, "Progress: dropped"),
    };
}

fn boardJson(c: *Ctx, l: *const Ledger, w: *Writer) !void {
    const h = l.host.?;
    const v = l.view();
    const reserved = core.reserved(v);
    var wsum: u64 = 0;
    for (h.params.weights) |x| wsum += x;
    try w.writeAll("{\"categories\":[");
    for (h.cats, 0..) |name, ci| {
        if (ci > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jcs.string(w, name);
        try w.writeAll(",\"share_target\":");
        try jcs.fraction(w, @as(f64, @floatFromInt(h.params.weights[ci])) / @as(f64, @floatFromInt(wsum)));
        try w.writeAll(",\"share_used\":");
        const u = core.used(v, l.decl.items, @intCast(ci));
        try jcs.fraction(w, if (reserved == 0) 0 else @as(f64, @floatFromInt(u)) / @as(f64, @floatFromInt(reserved)));
        try w.writeByte('}');
    }
    try w.writeAll("],\"generated_at\":");
    try jcs.string(w, &time.format(c.now));
    try w.print(",\"host\":{{\"cap\":{d},\"heavy_running\":{d},\"hold\":{},\"reserved\":{d},\"slots\":{d},\"workers\":{d}}}", .{
        h.params.cap, core.heavyRunning(v, l.decl.items), l.host_hold, reserved, h.params.slots, h.params.workers,
    });
    try w.writeAll(",\"jobs\":[");
    const order = try c.arena.alloc(usize, l.ids.items.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, l, struct {
        fn lt(ll: *const Ledger, x: usize, y: usize) bool {
            return std.mem.lessThan(u8, ll.ids.items[x], ll.ids.items[y]);
        }
    }.lt);
    for (order, 0..) |i, n| {
        const j = l.jobs.items[i];
        const r = l.revs.items[i];
        if (n > 0) try w.writeByte(',');
        try w.writeAll("{\"category\":");
        try jcs.string(w, r.category);
        try w.writeAll(",\"id\":");
        try jcs.string(w, r.id);
        try w.writeAll(",\"lease\":");
        if (j.st == .running) {
            try w.writeAll("{\"expires_at\":");
            try jcs.string(w, &time.format(l.lease_until.items[i]));
            try w.writeAll(",\"worker\":");
            try jcs.string(w, workerName(c, j.lease));
            try w.writeByte('}');
        } else try w.writeAll("null");
        try w.writeAll(",\"line\":");
        try jcs.string(w, try statusLine(c, l, i));
        try w.print(",\"measured\":{},\"owner\":", .{j.measured});
        try jcs.string(w, r.owner);
        try w.print(",\"priority\":{d},\"reason\":", .{r.priority});
        try jcs.string(w, reasonWords(j.reason));
        try w.print(",\"rejects\":{d},\"res\":{d},\"state\":", .{ j.rejects, j.res });
        try jcs.string(w, @tagName(j.st));
        try w.writeAll(",\"title\":");
        try jcs.string(w, r.title);
        try w.writeByte('}');
    }
    try w.writeAll("],\"schema\":\"work-queue/board/v1\"}\n");
}

fn boardText(c: *Ctx, l: *const Ledger, w: *Writer) !void {
    const h = l.host.?;
    try w.print("host rev {d}: reserved {d}/{d} GiB, heavy {d}/{d}, workers {d}{s}\n", .{
        h.rev,                                  core.reserved(l.view()), h.params.cap, core.heavyRunning(l.view(), l.decl.items), h.params.slots, h.params.workers,
        if (l.host_hold) ", HOST HELD" else "",
    });
    for (l.ids.items, 0..) |id, i| try w.print("{s}  {t}  {s}\n", .{ id, l.jobs.items[i].st, try statusLine(c, l, i) });
}

// ------------------------------------------------------------------ verbs

const usage_text =
    \\usage: q <verb> [args]
    \\  q add <file.toml>              store revision 1 of a new job (queued)
    \\  q amend <id> <file.toml>       new job revision (only while queued or dropped)
    \\  q record <id>                  queued -> ready, once the admission record is complete
    \\  q gate <id>                    say which guard blocks admission, in words
    \\  q admit <id>                   ready -> admitted
    \\  q start <id> --worker <wN>     admitted -> running, with a lease of the host TTL
    \\  q beat <id>                    extend the lease to now + TTL
    \\  q tick                         lapse every expired lease
    \\  q checkpoint <id>              running -> checkpoint (measurement recorded)
    \\  q accept <id> | q reject <id>  checkpoint -> completed | ready (or held at the reject limit)
    \\  q preempt <id>                 running -> ready, for a more urgent ready job
    \\  q hold <id> | q release <id> | q drop <id>
    \\  q host amend <file.toml>       new host revision
    \\  q host hold | q host release   close or reopen the gate for every job
    \\  q board [--json]               the board, as text or as work-queue/board/v1 JSON
    \\
;

const job_verbs = [_]struct { []const u8, Kind }{
    .{ "record", .record },         .{ "admit", .admit },   .{ "beat", .beat },
    .{ "checkpoint", .checkpoint }, .{ "accept", .accept }, .{ "reject", .reject },
    .{ "preempt", .preempt },       .{ "hold", .hold },     .{ "release", .release },
    .{ "drop", .drop },
};

fn run(c: *Ctx, args: []const []const u8) Fail!void {
    if (args.len == 0) return c.usage("no verb\n{s}", .{usage_text});
    const verb = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, verb, "board") or std.mem.eql(u8, verb, "gate")) {
        var s = try open(c, false);
        defer close(c, &s);
        if (s.l.host == null) return c.refuse("no host record yet: run q host amend first", .{});
        if (std.mem.eql(u8, verb, "board")) {
            if (rest.len == 1 and std.mem.eql(u8, rest[0], "--json")) {
                boardJson(c, &s.l, c.out) catch return c.internal("cannot write the board", .{});
            } else if (rest.len == 1 and std.mem.eql(u8, rest[0], "--html")) {
                return c.usage("board --html is tier 3 and not built yet", .{});
            } else if (rest.len == 0) {
                boardText(c, &s.l, c.out) catch return c.internal("cannot write the board", .{});
            } else return c.usage("board takes --json, or nothing", .{});
            return;
        }
        if (rest.len != 1) return c.usage("gate <id>", .{});
        const i = s.l.find(rest[0]) orelse return c.refuse("no such job: {s}", .{rest[0]});
        const msg = statusLine(c, &s.l, i) catch return c.internal("out of memory", .{});
        c.out.print("{s}  {t}  {s}\n", .{ rest[0], s.l.jobs.items[i].st, msg }) catch {};
        return;
    }

    var s = try open(c, true);
    defer close(c, &s);
    try tick(c, &s);

    if (std.mem.eql(u8, verb, "tick")) {
        if (rest.len != 0) return c.usage("tick takes no arguments", .{});
        return;
    }
    if (std.mem.eql(u8, verb, "add") or std.mem.eql(u8, verb, "amend")) {
        const is_add = std.mem.eql(u8, verb, "add");
        if (rest.len != @as(usize, if (is_add) 1 else 2)) return c.usage("{s}", .{if (is_add) "add <file.toml>" else "amend <id> <file.toml>"});
        const file = rest[rest.len - 1];
        const src = readFile(c, file) catch |e| return c.usage("cannot read {s}: {t}", .{ file, e });
        var rev: u32 = 1;
        if (!is_add) {
            const i = s.l.find(rest[0]) orelse return c.refuse("no such job: {s}", .{rest[0]});
            rev = s.l.revs.items[i].rev + 1;
        }
        const r = try jobFromSource(c, file, src, rev);
        if (!is_add and !std.mem.eql(u8, r.id, rest[0])) return c.usage("{s} has id {s}, not {s}", .{ file, r.id, rest[0] });
        // Check first; write the revision only once the event will apply.
        var probe = s.l;
        probe.ids = s.l.ids.clone(c.arena) catch return c.internal("out of memory", .{});
        probe.revs = s.l.revs.clone(c.arena) catch return c.internal("out of memory", .{});
        probe.decl = s.l.decl.clone(c.arena) catch return c.internal("out of memory", .{});
        probe.jobs = s.l.jobs.clone(c.arena) catch return c.internal("out of memory", .{});
        probe.lease_until = s.l.lease_until.clone(c.arena) catch return c.internal("out of memory", .{});
        probe.obligations = s.l.obligations.clone(c.arena) catch return c.internal("out of memory", .{});
        const ev = Event{ .kind = if (is_add) .add else .amend, .at = c.now, .seq = s.l.seq + 1, .job = r.id, .rev = rev };
        if (probe.apply(ev, null, r) catch return c.internal("out of memory", .{})) |why| return c.refuse("{s}", .{why.words});
        const dir = c.path(&.{ "jobs", r.id }) catch return c.internal("out of memory", .{});
        try writeRevision(c, dir, revName(c, rev) catch unreachable, src);
        return commit(c, &s, ev, null, r);
    }
    if (std.mem.eql(u8, verb, "host")) {
        if (rest.len == 0) return c.usage("host amend <file.toml> | host hold | host release", .{});
        if (std.mem.eql(u8, rest[0], "hold") and rest.len == 1)
            return commit(c, &s, .{ .kind = .host_hold, .at = c.now, .seq = 0 }, null, null);
        if (std.mem.eql(u8, rest[0], "release") and rest.len == 1)
            return commit(c, &s, .{ .kind = .host_release, .at = c.now, .seq = 0 }, null, null);
        if (std.mem.eql(u8, rest[0], "amend") and rest.len == 2) {
            const src = readFile(c, rest[1]) catch |e| return c.usage("cannot read {s}: {t}", .{ rest[1], e });
            const rev: u32 = if (s.l.host) |h| h.rev + 1 else 1;
            const h = try hostFromSource(c, rest[1], src, rev);
            var probe = s.l;
            probe.decl = s.l.decl.clone(c.arena) catch return c.internal("out of memory", .{});
            probe.obligations = s.l.obligations.clone(c.arena) catch return c.internal("out of memory", .{});
            const ev = Event{ .kind = .host_amend, .at = c.now, .seq = s.l.seq + 1, .rev = rev };
            if (probe.apply(ev, h, null) catch return c.internal("out of memory", .{})) |why| return c.refuse("{s}", .{why.words});
            try writeRevision(c, c.path(&.{"host"}) catch unreachable, revName(c, rev) catch unreachable, src);
            return commit(c, &s, ev, h, null);
        }
        return c.usage("host amend <file.toml> | host hold | host release", .{});
    }
    if (std.mem.eql(u8, verb, "start")) {
        if (rest.len != 3 or !std.mem.eql(u8, rest[1], "--worker")) return c.usage("start <id> --worker <wN>", .{});
        const i = s.l.find(rest[0]) orelse return c.refuse("no such job: {s}", .{rest[0]});
        return commit(c, &s, .{ .kind = .start, .at = c.now, .seq = 0, .job = rest[0], .rev = s.l.revs.items[i].rev, .worker = rest[2] }, null, null);
    }
    inline for (job_verbs) |jv| {
        if (std.mem.eql(u8, verb, jv[0])) {
            if (rest.len != 1) return c.usage("{s} <id>", .{jv[0]});
            const i = s.l.find(rest[0]) orelse return c.refuse("no such job: {s}", .{rest[0]});
            return commit(c, &s, .{ .kind = jv[1], .at = c.now, .seq = 0, .job = rest[0], .rev = s.l.revs.items[i].rev }, null, null);
        }
    }
    return c.usage("unknown verb {s}\n{s}", .{ verb, usage_text });
}

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    var obuf: [8192]u8 = undefined;
    var ebuf: [1024]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    var ew = Io.File.stderr().writer(io, &ebuf);
    const code = body(init, io, arena, &ow.interface, &ew.interface);
    ow.interface.flush() catch {};
    ew.interface.flush() catch {};
    return @backingInt(code);
}

fn body(init: std.process.Init, io: Io, arena: std.mem.Allocator, out: *Writer, err: *Writer) Exit {
    const argv = init.minimal.args.toSlice(arena) catch return .internal;
    const env = init.environ_map;
    const home = env.get("WQ_HOME") orelse blk: {
        if (env.get("XDG_STATE_HOME")) |x| if (x.len > 0) break :blk std.fs.path.join(arena, &.{ x, "work-queue" }) catch return .internal;
        const h = env.get("HOME") orelse {
            err.writeAll("q: set WQ_HOME, XDG_STATE_HOME or HOME\n") catch {};
            return .usage;
        };
        break :blk std.fs.path.join(arena, &.{ h, ".local", "state", "work-queue" }) catch return .internal;
    };
    const now = if (env.get("WQ_NOW")) |s| time.parse(s) catch {
        err.writeAll("q: WQ_NOW is not an RFC 3339 UTC time like 2026-11-18T09:00:00Z\n") catch {};
        return .usage;
    } else Io.Timestamp.now(io, .real).toSeconds();
    var c = Ctx{ .io = io, .arena = arena, .home = home, .now = now, .out = out, .err = err };
    const args = arena.alloc([]const u8, argv.len - 1) catch return .internal;
    for (argv[1..], 0..) |a, i| args[i] = a;
    run(&c, args) catch |e| return switch (e) {
        error.Usage => .usage,
        error.Refused => .refused,
        error.Internal => .internal,
    };
    return .done;
}

test {
    _ = toml;
    _ = time;
    _ = jcs;
    _ = ledger;
}
