// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! The ledger: current state as the fold of the event log through the core.
//!
//! `apply` is the only way state changes, on replay and on write alike: a
//! verb builds its event, `apply` checks it (shell guards, then the core's
//! `transition`), and only an applied event is appended to the log. Replay
//! runs the same checks, so a log that a guard would refuse is corrupt and
//! the tool stops (exit 1) instead of folding it.
//!
//! Records are immutable revisions. Each event is checked against the job
//! and host revisions in force when it was appended, which are exactly the
//! ones in force at that point of the fold.

const std = @import("std");
const core = @import("queue");
const toml = @import("toml.zig");

pub const Host = struct {
    rev: u32,
    params: core.Params,
    ttl: i64, // lease TTL, seconds
    cats: []const []const u8, // category names, sorted; index = core cat
};

pub const JobRev = struct {
    rev: u32,
    id: []const u8,
    title: []const u8,
    category: []const u8,
    owner: []const u8,
    priority: u8,
    heavy: bool,
    obligation: []const u8,
    need: u32, // GiB, from admission.resources.ram_gib (0 when absent)
    ckpt: bool, // declares a checkpoint
    /// The first admission field that is missing, or null when the record
    /// is complete (contract section 2: required before `ready`).
    missing: ?[]const u8,
};

pub const Kind = enum {
    host_amend,
    add,
    amend,
    record,
    admit,
    start,
    beat,
    lease_lapse,
    checkpoint,
    accept,
    reject,
    preempt,
    hold,
    release,
    drop,
    host_hold,
    host_release,

    pub fn coreTag(k: Kind) ?core.Tag {
        return switch (k) {
            .host_amend, .add, .amend => null,
            .record => .record,
            .admit => .admit,
            .start => .start,
            .beat => .beat,
            .lease_lapse => .lease_lapse,
            .checkpoint => .checkpoint,
            .accept => .accept,
            .reject => .reject,
            .preempt => .preempt,
            .hold => .hold,
            .release => .release,
            .drop => .drop,
            .host_hold => .host_hold_on,
            .host_release => .host_hold_off,
        };
    }

    pub fn isHostEvent(k: Kind) bool {
        return k == .host_amend or k == .host_hold or k == .host_release;
    }
};

pub const Event = struct {
    kind: Kind,
    at: i64,
    seq: u64,
    job: []const u8 = "",
    rev: u32 = 0, // job revision for job events; host revision for host_amend
    worker: []const u8 = "",
};

/// Why an event cannot be applied, in words for the owner.
pub const Refusal = struct { words: []const u8 };

pub const Ledger = struct {
    arena: std.mem.Allocator,
    host: ?Host = null,
    ids: std.ArrayList([]const u8) = .empty,
    revs: std.ArrayList(JobRev) = .empty,
    decl: std.ArrayList(core.Decl) = .empty,
    jobs: std.ArrayList(core.Job) = .empty,
    lease_until: std.ArrayList(i64) = .empty, // meaningful while running
    host_hold: bool = false,
    seq: u64 = 0,
    obligations: std.ArrayList([]const u8) = .empty,

    pub fn view(l: *const Ledger) core.View {
        return .{ .jobs = l.jobs.items, .host_hold = l.host_hold };
    }

    pub fn find(l: *const Ledger, id: []const u8) ?u32 {
        for (l.ids.items, 0..) |x, i| if (std.mem.eql(u8, x, id)) return @intCast(i);
        return null;
    }

    pub fn workerIndex(l: *const Ledger, name: []const u8) ?u32 {
        const h = l.host orelse return null;
        if (name.len < 2 or name[0] != 'w') return null;
        const n = std.fmt.parseInt(u32, name[1..], 10) catch return null;
        if (n < 1 or n > h.params.workers or name[1] == '0') return null;
        return n - 1;
    }

    fn oblIndex(l: *Ledger, name: []const u8) !u32 {
        for (l.obligations.items, 0..) |x, i| if (std.mem.eql(u8, x, name)) return @intCast(i);
        try l.obligations.append(l.arena, name);
        return @intCast(l.obligations.items.len - 1);
    }

    fn catIndex(h: Host, name: []const u8) ?u32 {
        for (h.cats, 0..) |c, i| if (std.mem.eql(u8, c, name)) return @intCast(i);
        return null;
    }

    fn declOf(l: *Ledger, h: Host, r: JobRev) !core.Decl {
        return .{
            .need = r.need,
            .heavy = r.heavy,
            .prio = r.priority,
            .ckpt = r.ckpt,
            .obl = try l.oblIndex(r.obligation),
            .cat = catIndex(h, r.category).?,
        };
    }

    /// Check an event and, if every guard passes, apply it. `host_rec` and
    /// `job_rec` carry the parsed record for host_amend, add and amend.
    pub fn apply(l: *Ledger, ev: Event, host_rec: ?Host, job_rec: ?JobRev) !?Refusal {
        if (ev.seq != l.seq + 1) return .{ .words = "event sequence number is not the next one" };
        switch (ev.kind) {
            .host_amend => {
                const h = host_rec.?;
                const want: u32 = if (l.host) |o| o.rev + 1 else 1;
                if (ev.rev != want or h.rev != want) return .{ .words = "host revision is not the next one" };
                for (l.jobs.items) |j| switch (j.st) {
                    .queued, .completed, .dropped => {},
                    else => return .{ .words = "host amend is refused while any job is past queued and not finished: revisions are not in the spec yet" },
                };
                if (core.reserved(l.view()) > h.params.cap) return .{ .words = "the new capacity is below the reserved total" };
                for (l.revs.items) |r| if (catIndex(h, r.category) == null) return .{ .words = "the new host revision drops a category a job uses" };
                l.host = h;
                for (l.revs.items, 0..) |r, i| l.decl.items[i] = try l.declOf(h, r);
            },
            .add => {
                const h = l.host orelse return .{ .words = "no host record yet: run q host amend first" };
                const r = job_rec.?;
                if (l.find(ev.job) != null) return .{ .words = "a job with this id already exists" };
                if (ev.rev != 1 or r.rev != 1 or !std.mem.eql(u8, r.id, ev.job)) return .{ .words = "a new job starts at revision 1 with the event's id" };
                if (catIndex(h, r.category) == null) return .{ .words = "the category is not in the host's share table" };
                try l.ids.append(l.arena, r.id);
                try l.revs.append(l.arena, r);
                try l.decl.append(l.arena, try l.declOf(h, r));
                try l.jobs.append(l.arena, .{});
                try l.lease_until.append(l.arena, 0);
            },
            .amend => {
                const h = l.host.?;
                const r = job_rec.?;
                const i = l.find(ev.job) orelse return .{ .words = "no such job" };
                if (ev.rev != l.revs.items[i].rev + 1 or r.rev != ev.rev or !std.mem.eql(u8, r.id, ev.job)) return .{ .words = "job revision is not the next one, or its id differs" };
                switch (l.jobs.items[i].st) {
                    .queued, .dropped => {},
                    else => return .{ .words = "amend is refused unless the job is queued or dropped: revisions are not in the spec yet" },
                }
                if (catIndex(h, r.category) == null) return .{ .words = "the category is not in the host's share table" };
                l.revs.items[i] = r;
                l.decl.items[i] = try l.declOf(h, r);
            },
            else => {
                const h = l.host orelse return .{ .words = "no host record yet: run q host amend first" };
                var a = core.Action{ .tag = ev.kind.coreTag().? };
                var i: u32 = 0;
                if (!ev.kind.isHostEvent()) {
                    i = l.find(ev.job) orelse return .{ .words = "no such job" };
                    if (ev.rev != l.revs.items[i].rev) return .{ .words = "the event names a job revision that is not current" };
                    a.job = i;
                }
                // Shell guards: facts the model takes as given.
                switch (ev.kind) {
                    .record => if (l.revs.items[i].missing) |m| return .{ .words = m },
                    .start => a.worker = l.workerIndex(ev.worker) orelse return .{ .words = "no such worker" },
                    .lease_lapse => if (l.jobs.items[i].st == .running and ev.at < l.lease_until.items[i])
                        return .{ .words = "the lease has not expired" },
                    else => {},
                }
                switch (core.transition(l.view(), l.decl.items, h.params, a)) {
                    .refused => |g| return .{ .words = g.words() },
                    .ok => |e| core.apply(l.jobs.items, &l.host_hold, e),
                }
                if (ev.kind == .start or ev.kind == .beat) l.lease_until.items[i] = ev.at + h.ttl;
            },
        }
        l.seq = ev.seq;
        return null;
    }
};

// ---------------------------------------------------------------- records

pub const RecordError = error{BadRecord} || std.mem.Allocator.Error;

pub const Problem = struct { msg: []const u8 = "" };

fn str(t: toml.Table, k: []const u8, p: *Problem) RecordError!?[]const u8 {
    const v = t.get(k) orelse return null;
    if (v != .string) {
        p.msg = k;
        return error.BadRecord;
    }
    return v.string;
}

fn reqStr(t: toml.Table, k: []const u8, p: *Problem) RecordError![]const u8 {
    return (try str(t, k, p)) orelse {
        p.msg = k;
        return error.BadRecord;
    };
}

fn onlyKeys(t: toml.Table, allowed: []const []const u8, p: *Problem) RecordError!void {
    outer: for (t.entries) |e| {
        for (allowed) |a| if (std.mem.eql(u8, a, e.key)) continue :outer;
        p.msg = e.key;
        return error.BadRecord;
    }
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or id[0] == '.' or id[0] == '-') return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

/// A job record (CONTRACT section 2). `p.msg` names the offending key.
pub fn parseJob(arena: std.mem.Allocator, t: toml.Table, rev: u32, p: *Problem) RecordError!JobRev {
    try onlyKeys(t, &.{ "id", "title", "category", "priority", "owner", "repos", "heavy", "obligation", "admission", "limits" }, p);
    const id = try reqStr(t, "id", p);
    if (!validId(id)) {
        p.msg = "id (letters, digits, - _ . only; not starting with . or -)";
        return error.BadRecord;
    }
    const pri = t.get("priority") orelse {
        p.msg = "priority";
        return error.BadRecord;
    };
    if (pri != .int or pri.int < 1 or pri.int > 4) {
        p.msg = "priority (an integer 1..4)";
        return error.BadRecord;
    }
    var heavy = true; // a job takes a heavy slot unless it says otherwise
    if (t.get("heavy")) |h| {
        if (h != .boolean) {
            p.msg = "heavy";
            return error.BadRecord;
        }
        heavy = h.boolean;
    }
    var r = JobRev{
        .rev = rev,
        .id = id,
        .title = try reqStr(t, "title", p),
        .category = try reqStr(t, "category", p),
        .owner = (try str(t, "owner", p)) orelse "",
        .priority = @intCast(pri.int),
        .heavy = heavy,
        .obligation = (try str(t, "obligation", p)) orelse id,
        .need = 0,
        .ckpt = false,
        .missing = null,
    };
    if (r.owner.len == 0) r.missing = "the owner is empty";
    const adm_v = t.get("admission") orelse {
        if (r.missing == null) r.missing = "no [admission] record";
        return r;
    };
    if (adm_v != .table) {
        p.msg = "admission";
        return error.BadRecord;
    }
    const adm = adm_v.table;
    try onlyKeys(adm, &.{ "purpose", "command", "cwd", "ownership", "resources", "duration", "checkpoint", "accept" }, p);
    for ([_][]const u8{ "purpose", "command", "cwd", "ownership", "duration", "checkpoint", "accept" }) |k| {
        const s: []const u8 = (try str(adm, k, p)) orelse "";
        if (s.len == 0 and r.missing == null) r.missing = try std.fmt.allocPrint(arena, "admission field {s} is missing", .{k});
    }
    const ck: []const u8 = (try str(adm, "checkpoint", p)) orelse "";
    // The behaviour must be stated; "none" states that there is no checkpoint,
    // so the job cannot be preempted (the spec's Ckpt = FALSE).
    r.ckpt = ck.len > 0 and !std.mem.eql(u8, ck, "none");
    if (adm.get("duration")) |d| if (d == .string and d.string.len > 0) {
        _ = @import("time.zig").parseDuration(d.string) catch {
            p.msg = "admission.duration (like 40m or 1h30m)";
            return error.BadRecord;
        };
    };
    if (adm.get("resources")) |rv| {
        if (rv != .table) {
            p.msg = "admission.resources";
            return error.BadRecord;
        }
        const ram = rv.table.get("ram_gib");
        if (ram) |x| {
            const g: f64 = switch (x) {
                .int => |n| @floatFromInt(n),
                .float => |f| f,
                else => {
                    p.msg = "admission.resources.ram_gib";
                    return error.BadRecord;
                },
            };
            if (!(g > 0 and g <= 1 << 20)) {
                p.msg = "admission.resources.ram_gib (a number > 0)";
                return error.BadRecord;
            }
            r.need = @intFromFloat(@ceil(g)); // whole GiB, rounded up
        } else if (r.missing == null) r.missing = "admission field resources.ram_gib is missing";
    } else if (r.missing == null) r.missing = "admission field resources is missing";
    return r;
}

fn reqInt(t: toml.Table, k: []const u8, lo: i64, hi: i64, p: *Problem) RecordError!i64 {
    const v = t.get(k) orelse {
        p.msg = k;
        return error.BadRecord;
    };
    if (v != .int or v.int < lo or v.int > hi) {
        p.msg = k;
        return error.BadRecord;
    }
    return v.int;
}

/// A host record. Share weights are positive integers (exact comparison in
/// the core); the board shows each as weight / sum of weights.
pub fn parseHost(arena: std.mem.Allocator, t: toml.Table, rev: u32, p: *Problem) RecordError!Host {
    try onlyKeys(t, &.{ "capacity_gib", "heavy_slots", "probe_gib", "reject_limit", "workers", "lease_ttl", "shares" }, p);
    const ttl_s = try reqStr(t, "lease_ttl", p);
    const ttl = @import("time.zig").parseDuration(ttl_s) catch {
        p.msg = "lease_ttl (like 15m)";
        return error.BadRecord;
    };
    const sv = t.get("shares") orelse {
        p.msg = "shares";
        return error.BadRecord;
    };
    if (sv != .table or sv.table.entries.len == 0) {
        p.msg = "shares (a table of category = positive integer weight)";
        return error.BadRecord;
    }
    const ents = try arena.dupe(toml.Entry, sv.table.entries);
    std.mem.sort(toml.Entry, ents, {}, struct {
        fn lt(_: void, a: toml.Entry, b: toml.Entry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    const cats = try arena.alloc([]const u8, ents.len);
    const weights = try arena.alloc(u32, ents.len);
    for (ents, 0..) |e, i| {
        if (e.value != .int or e.value.int < 1 or e.value.int > 1_000_000) {
            p.msg = try std.fmt.allocPrint(arena, "shares.{s} (a positive integer weight)", .{e.key});
            return error.BadRecord;
        }
        cats[i] = e.key;
        weights[i] = @intCast(e.value.int);
    }
    const cap = try reqInt(t, "capacity_gib", 1, 1 << 20, p);
    const probe = try reqInt(t, "probe_gib", 1, cap, p);
    return .{
        .rev = rev,
        .ttl = ttl,
        .cats = cats,
        .params = .{
            .cap = @intCast(cap),
            .slots = @intCast(try reqInt(t, "heavy_slots", 0, 1024, p)),
            .probe_cap = @intCast(probe),
            .max_rejects = @intCast(try reqInt(t, "reject_limit", 1, 100, p)),
            .use_reject_bound = true,
            .workers = @intCast(try reqInt(t, "workers", 1, 64, p)),
            .weights = weights,
        },
    };
}
