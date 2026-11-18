// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Functional core of the work queue: one pure transition function per action
//! of verification/proofs/tlaplus/workqueue/WorkQueue.tla. No clock, no I/O,
//! no allocation. The shell (store, CLI, lease timer, launcher) maps real events
//! onto these actions; conformance is checked against the TLC state graph.

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

pub const no_worker: u8 = 0xff;

pub const Job = struct {
    st: St = .queued,
    reason: Reason = .no_record,
    lease: u8 = no_worker,
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
    workers: u8,
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
};

pub const Action = struct {
    tag: Tag,
    job: u8 = 0,
    worker: u8 = 0,
};

pub fn Queue(comptime n: usize) type {
    return struct {
        const Self = @This();
        pub const N = n;

        jobs: [n]Job = @splat(.{}),
        host_hold: bool = false,

        fn isActive(s: St) bool {
            return s == .admitted or s == .running or s == .checkpoint;
        }

        pub fn reserved(self: Self) u32 {
            var t: u32 = 0;
            for (self.jobs) |j| t += j.res;
            return t;
        }

        fn sizeFor(self: Self, d: []const Decl, p: Params, j: usize) u32 {
            return if (self.jobs[j].measured) d[j].need else p.probe_cap;
        }

        fn fits(self: Self, d: []const Decl, p: Params, j: usize) bool {
            const r = self.reserved();
            if (r > p.cap) return false;
            return self.sizeFor(d, p, j) <= p.cap - r;
        }

        fn heavyRunning(self: Self, d: []const Decl) u32 {
            var c: u32 = 0;
            for (self.jobs, 0..) |j, i| {
                if (j.st == .running and d[i].heavy) c += 1;
            }
            return c;
        }

        /// The successor state, or null when the action is not enabled.
        pub fn step(self: Self, d: []const Decl, p: Params, a: Action) ?Self {
            var t = self;
            if (a.tag == .host_hold_on) {
                if (self.host_hold) return null;
                t.host_hold = true;
                return t;
            }
            if (a.tag == .host_hold_off) {
                if (!self.host_hold) return null;
                t.host_hold = false;
                return t;
            }
            const j = a.job;
            if (j >= n) return null;
            const cur = self.jobs[j];
            var nj = cur;
            switch (a.tag) {
                .record => {
                    if (cur.st != .queued) return null;
                    nj.st = .ready;
                    nj.reason = .gate;
                },
                .admit => {
                    if (cur.st != .ready or self.host_hold or !self.fits(d, p, j)) return null;
                    for (self.jobs, 0..) |k, ki| {
                        if (ki == j) continue;
                        if (k.st == .ready and d[ki].prio < d[j].prio and self.fits(d, p, ki)) return null;
                        if (d[ki].obl == d[j].obl and isActive(k.st)) return null;
                    }
                    nj.st = .admitted;
                    nj.res = self.sizeFor(d, p, j);
                    nj.reason = .awaiting_start;
                },
                .start => {
                    if (cur.st != .admitted or a.worker >= p.workers) return null;
                    for (self.jobs) |k| if (k.lease == a.worker) return null;
                    if (d[j].heavy and self.heavyRunning(d) >= p.slots) return null;
                    nj.st = .running;
                    nj.lease = a.worker;
                    nj.reason = .none;
                },
                .lease_lapse => {
                    if (cur.st != .running) return null;
                    nj.st = .held;
                    nj.lease = no_worker;
                    nj.res = 0;
                    nj.reason = .lease_expired;
                },
                .checkpoint => {
                    if (cur.st != .running) return null;
                    nj.st = .checkpoint;
                    nj.lease = no_worker;
                    nj.measured = true;
                    nj.reason = .validating;
                },
                .accept => {
                    if (cur.st != .checkpoint) return null;
                    nj.st = .completed;
                    nj.res = 0;
                    nj.reason = .none;
                },
                .reject => {
                    if (cur.st != .checkpoint) return null;
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
                    if (cur.st != .running or !d[j].ckpt) return null;
                    var higher = false;
                    for (self.jobs, 0..) |k, ki| {
                        if (k.st == .ready and d[ki].prio < d[j].prio) higher = true;
                    }
                    if (!higher) return null;
                    nj.st = .ready;
                    nj.lease = no_worker;
                    nj.res = 0;
                    nj.reason = .preempted;
                },
                .hold => {
                    switch (cur.st) {
                        .ready, .admitted, .running, .checkpoint => {},
                        else => return null,
                    }
                    nj.st = .held;
                    nj.lease = no_worker;
                    nj.res = 0;
                    nj.reason = .held_by_owner;
                },
                .release => {
                    if (cur.st != .held or cur.reason == .reject_limit) return null;
                    nj.st = .ready;
                    nj.reason = .gate;
                },
                .drop => {
                    switch (cur.st) {
                        .queued, .ready, .held => {},
                        else => return null,
                    }
                    nj.st = .dropped;
                    nj.res = 0;
                    nj.reason = .none;
                },
                .host_hold_on, .host_hold_off => unreachable,
            }
            t.jobs[j] = nj;
            return t;
        }

        /// Contract section 3 rules, as runtime checks. Returns the first
        /// broken rule's name, or null when all hold.
        pub fn brokenRule(self: Self, d: []const Decl, p: Params) ?[]const u8 {
            for (self.jobs, 0..) |j, i| {
                if ((j.lease != no_worker) != (j.st == .running)) return "R1_OneLeasePerJobAndWorker";
                for (self.jobs, 0..) |k, ki| {
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
            if (self.heavyRunning(d) > p.slots) return "R1_HeavySlots";
            if (self.reserved() > p.cap) return "R4_Reservation";
            return null;
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
