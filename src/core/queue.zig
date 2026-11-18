// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Functional core of the work queue: one pure transition function per action
//! of verification/proofs/tlaplus/workqueue/WorkQueue.tla. No clock, no I/O,
//! no allocation. The shell (store, CLI, lease timer, launcher) owns the job
//! table, maps real events onto these actions and applies the effect the core
//! returns; conformance is checked against the TLC state graph.
//!
//! Every action of the spec changes the record of at most one job, or only
//! the host hold flag. `Effect` states that in the type: the core cannot
//! return a transition that touches two jobs.

const std = @import("std");

pub const St = enum(u8) { queued, ready, admitted, running, checkpoint, held, completed, dropped };

pub const Reason = enum(u8) {
    none,
    no_record,
    gate,
    awaiting_start,
    validating,
    lease_expired,
    held_by_owner,
    preempted,
    reject_limit,
};

pub const no_worker: u32 = std.math.maxInt(u32);

pub const Job = struct {
    st: St = .queued,
    reason: Reason = .no_record,
    lease: u32 = no_worker,
    res: u32 = 0,
    measured: bool = false,
    rejects: u8 = 0,
};

/// Per-job declared facts (the TLA+ constants Need, Heavy, Prio, Ckpt, Obl).
pub const Decl = struct {
    need: u32,
    heavy: bool,
    prio: u8, // lower = more urgent
    ckpt: bool,
    obl: u32, // obligation id; two jobs with one obligation never run together
};

pub const Params = struct {
    cap: u32,
    slots: u32,
    probe_cap: u32,
    max_rejects: u8,
    use_reject_bound: bool,
    workers: u32,
};

pub const Tag = enum(u8) {
    record,
    admit,
    start,
    lease_lapse,
    checkpoint,
    accept,
    reject,
    preempt,
    hold,
    release,
    drop,
    host_hold_on,
    host_hold_off,
    beat,
};

pub const Action = struct {
    tag: Tag,
    job: u32 = 0,
    worker: u32 = 0,
};

/// Why the core refuses an action: the first guard of the spec action that
/// is false. Shown to the owner by `q gate` and on exit code 3.
pub const Guard = enum(u8) {
    no_such_job,
    wrong_state,
    host_hold,
    no_fit,
    higher_priority,
    obligation_active,
    no_such_worker,
    worker_busy,
    heavy_slots_full,
    not_checkpointable,
    no_higher_priority_ready,
    reject_limit,
    host_not_held,
    host_already_held,

    pub fn words(g: Guard) []const u8 {
        return switch (g) {
            .no_such_job => "no such job",
            .wrong_state => "the job is not in a state this action starts from",
            .host_hold => "the host is held",
            .no_fit => "the job's reservation does not fit in free capacity",
            .higher_priority => "a more urgent ready job fits and goes first",
            .obligation_active => "another job for the same obligation is active",
            .no_such_worker => "no such worker",
            .worker_busy => "the worker already holds a lease",
            .heavy_slots_full => "every heavy slot is taken",
            .not_checkpointable => "the job declares no checkpoint, so it cannot be preempted",
            .no_higher_priority_ready => "no more urgent job is ready",
            .reject_limit => "the job hit the reject limit and needs an owner edit",
            .host_not_held => "the host is not held",
            .host_already_held => "the host is already held",
        };
    }
};

/// The one change an enabled action makes.
pub const Effect = union(enum) {
    job: struct { index: u32, job: Job },
    host_hold: bool,
};

pub const Outcome = union(enum) {
    ok: Effect,
    refused: Guard,
};

/// A read-only view of the state; the shell owns the storage.
pub const View = struct {
    jobs: []const Job,
    host_hold: bool,
};

fn isActive(s: St) bool {
    return s == .admitted or s == .running or s == .checkpoint;
}

pub fn reserved(v: View) u64 {
    var t: u64 = 0;
    for (v.jobs) |j| t += j.res;
    return t;
}

fn sizeFor(v: View, d: []const Decl, p: Params, j: usize) u32 {
    return if (v.jobs[j].measured) d[j].need else p.probe_cap;
}

fn fits(v: View, d: []const Decl, p: Params, j: usize) bool {
    const r = reserved(v);
    if (r > p.cap) return false;
    return sizeFor(v, d, p, j) <= p.cap - r;
}

pub fn heavyRunning(v: View, d: []const Decl) u64 {
    var c: u64 = 0;
    for (v.jobs, 0..) |j, i| {
        if (j.st == .running and d[i].heavy) c += 1;
    }
    return c;
}

/// The first false guard of the spec action, or the effect it makes.
pub fn transition(v: View, d: []const Decl, p: Params, a: Action) Outcome {
    std.debug.assert(d.len == v.jobs.len);
    if (a.tag == .host_hold_on) {
        if (v.host_hold) return .{ .refused = .host_already_held };
        return .{ .ok = .{ .host_hold = true } };
    }
    if (a.tag == .host_hold_off) {
        if (!v.host_hold) return .{ .refused = .host_not_held };
        return .{ .ok = .{ .host_hold = false } };
    }
    const j = a.job;
    if (j >= v.jobs.len) return .{ .refused = .no_such_job };
    const cur = v.jobs[j];
    var nj = cur;
    switch (a.tag) {
        .record => {
            if (cur.st != .queued) return .{ .refused = .wrong_state };
            nj.st = .ready;
            nj.reason = .gate;
        },
        .admit => {
            if (cur.st != .ready) return .{ .refused = .wrong_state };
            if (v.host_hold) return .{ .refused = .host_hold };
            if (!fits(v, d, p, j)) return .{ .refused = .no_fit };
            for (v.jobs, 0..) |k, ki| {
                if (ki == j) continue;
                if (k.st == .ready and d[ki].prio < d[j].prio and fits(v, d, p, ki)) return .{ .refused = .higher_priority };
                if (d[ki].obl == d[j].obl and isActive(k.st)) return .{ .refused = .obligation_active };
            }
            nj.st = .admitted;
            nj.res = sizeFor(v, d, p, j);
            nj.reason = .awaiting_start;
        },
        .start => {
            if (cur.st != .admitted) return .{ .refused = .wrong_state };
            if (a.worker >= p.workers) return .{ .refused = .no_such_worker };
            for (v.jobs) |k| if (k.lease == a.worker) return .{ .refused = .worker_busy };
            if (d[j].heavy and heavyRunning(v, d) >= p.slots) return .{ .refused = .heavy_slots_full };
            nj.st = .running;
            nj.lease = a.worker;
            nj.reason = .none;
        },
        .lease_lapse => {
            if (cur.st != .running) return .{ .refused = .wrong_state };
            nj.st = .held;
            nj.lease = no_worker;
            nj.res = 0;
            nj.reason = .lease_expired;
        },
        .checkpoint => {
            if (cur.st != .running) return .{ .refused = .wrong_state };
            nj.st = .checkpoint;
            nj.lease = no_worker;
            nj.measured = true;
            nj.reason = .validating;
        },
        .accept => {
            if (cur.st != .checkpoint) return .{ .refused = .wrong_state };
            nj.st = .completed;
            nj.res = 0;
            nj.reason = .none;
        },
        .reject => {
            if (cur.st != .checkpoint) return .{ .refused = .wrong_state };
            nj.res = 0;
            if (cur.rejects < p.max_rejects) nj.rejects = cur.rejects + 1;
            if (p.use_reject_bound and @as(u32, cur.rejects) + 1 >= p.max_rejects) {
                nj.st = .held;
                nj.reason = .reject_limit;
            } else {
                nj.st = .ready;
                nj.reason = .gate;
            }
        },
        .preempt => {
            if (cur.st != .running) return .{ .refused = .wrong_state };
            if (!d[j].ckpt) return .{ .refused = .not_checkpointable };
            var higher = false;
            for (v.jobs, 0..) |k, ki| {
                if (k.st == .ready and d[ki].prio < d[j].prio) higher = true;
            }
            if (!higher) return .{ .refused = .no_higher_priority_ready };
            nj.st = .ready;
            nj.lease = no_worker;
            nj.res = 0;
            nj.reason = .preempted;
        },
        .hold => {
            switch (cur.st) {
                .ready, .admitted, .running, .checkpoint => {},
                else => return .{ .refused = .wrong_state },
            }
            nj.st = .held;
            nj.lease = no_worker;
            nj.res = 0;
            nj.reason = .held_by_owner;
        },
        .release => {
            if (cur.st != .held) return .{ .refused = .wrong_state };
            if (cur.reason == .reject_limit) return .{ .refused = .reject_limit };
            nj.st = .ready;
            nj.reason = .gate;
        },
        .drop => {
            switch (cur.st) {
                .queued, .ready, .held => {},
                else => return .{ .refused = .wrong_state },
            }
            nj.st = .dropped;
            nj.res = 0;
            nj.reason = .none;
        },
        .beat => {
            // Heartbeat: the shell extends the lease. No modelled
            // state changes; allowed only while running.
            if (cur.st != .running) return .{ .refused = .wrong_state };
        },
        .host_hold_on, .host_hold_off => unreachable,
    }
    return .{ .ok = .{ .job = .{ .index = j, .job = nj } } };
}

/// The effect of an enabled action, or null when it is not enabled.
pub fn step(v: View, d: []const Decl, p: Params, a: Action) ?Effect {
    return switch (transition(v, d, p, a)) {
        .ok => |e| e,
        .refused => null,
    };
}

/// Apply an effect to state the caller owns.
pub fn apply(jobs: []Job, host_hold: *bool, e: Effect) void {
    switch (e) {
        .job => |x| jobs[x.index] = x.job,
        .host_hold => |h| host_hold.* = h,
    }
}

/// Contract section 3 rules, as runtime checks. Returns the first
/// broken rule's name, or null when all hold.
pub fn brokenRule(v: View, d: []const Decl, p: Params) ?[]const u8 {
    for (v.jobs, 0..) |j, i| {
        if ((j.lease != no_worker) != (j.st == .running)) return "R1_OneLeasePerJobAndWorker";
        for (v.jobs, 0..) |k, ki| {
            if (ki != i and j.lease != no_worker and j.lease == k.lease) return "R1_OneLeasePerJobAndWorker";
            if (ki != i and d[i].obl == d[ki].obl and isActive(j.st) and isActive(k.st)) return "Ownership";
        }
        switch (j.st) {
            .running, .completed, .dropped => {},
            else => if (j.reason == .none) return "R2_WaitingSaid",
        }
        if ((j.res > 0) != isActive(j.st)) return "R4_Reservation";
        if (isActive(j.st) and !j.measured and j.res != p.probe_cap) return "R6_ProbeCapped";
    }
    if (heavyRunning(v, d) > p.slots) return "R1_HeavySlots";
    if (reserved(v) > p.cap) return "R4_Reservation";
    return null;
}

const effectOf = step;
const rulesOf = brokenRule;

/// A fixed-size state with value semantics, for tests and conformance.
pub fn Queue(comptime n: usize) type {
    return struct {
        const Self = @This();
        pub const N = n;

        jobs: [n]Job = @splat(.{}),
        host_hold: bool = false,

        pub fn view(self: *const Self) View {
            return .{ .jobs = &self.jobs, .host_hold = self.host_hold };
        }

        /// The successor state, or null when the action is not enabled.
        pub fn step(self: Self, d: []const Decl, p: Params, a: Action) ?Self {
            const e = effectOf(self.view(), d, p, a) orelse return null;
            var t = self;
            apply(&t.jobs, &t.host_hold, e);
            return t;
        }

        pub fn brokenRule(self: Self, d: []const Decl, p: Params) ?[]const u8 {
            return rulesOf(self.view(), d, p);
        }
    };
}

test "a fresh queue keeps every rule" {
    const Q = Queue(1);
    const d = [_]Decl{.{ .need = 1, .heavy = false, .prio = 1, .ckpt = false, .obl = 1 }};
    const p = Params{ .cap = 4, .slots = 1, .probe_cap = 2, .max_rejects = 2, .use_reject_bound = true, .workers = 1 };
    const q = Q{};
    try std.testing.expectEqual(@as(?[]const u8, null), q.brokenRule(&d, p));
    try std.testing.expect(q.step(&d, p, .{ .tag = .admit }) == null);
    const r = q.step(&d, p, .{ .tag = .record }).?;
    try std.testing.expectEqual(St.ready, r.jobs[0].st);
}

test "a job table of runtime size: refusals name the guard" {
    const gpa = std.testing.allocator;
    const n = 40;
    const jobs = try gpa.alloc(Job, n);
    defer gpa.free(jobs);
    @memset(jobs, .{});
    var d: [n]Decl = undefined;
    for (&d, 0..) |*x, i| x.* = .{ .need = 1, .heavy = false, .prio = @intCast(1 + i % 4), .ckpt = true, .obl = @intCast(i) };
    const p = Params{ .cap = 3, .slots = 1, .probe_cap = 1, .max_rejects = 2, .use_reject_bound = true, .workers = 2 };
    var hh = false;
    for (0..n) |i| apply(jobs, &hh, step(.{ .jobs = jobs, .host_hold = hh }, &d, p, .{ .tag = .record, .job = @intCast(i) }).?);
    const v = View{ .jobs = jobs, .host_hold = hh };
    // job 1 has priority 2; job 0 (priority 1) is ready and fits.
    try std.testing.expectEqual(Outcome{ .refused = .higher_priority }, transition(v, &d, p, .{ .tag = .admit, .job = 1 }));
    try std.testing.expectEqual(Outcome{ .refused = .no_such_job }, transition(v, &d, p, .{ .tag = .admit, .job = n }));
    try std.testing.expect(step(v, &d, p, .{ .tag = .admit, .job = 0 }) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), brokenRule(v, &d, p));
}
