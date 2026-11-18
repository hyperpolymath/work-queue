// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! The control loop of `q run`. It adds no state transition: the only things
//! it can ask of the queue are `beat`, `checkpoint` and (through the store's
//! tick) `lease_lapse`, each applied by the shell through the core's guards.
//!
//! The loop is generic over three duck-typed collaborators so tests can
//! substitute fakes that record calls and simulate exit, lapse and preempt:
//!   store: observe() Lease, beat() Lease, checkpoint() Checkpoint
//!   proc:  poll() ?Status, term() void, forceStop() void
//!   env:   nowMs() u64, sleepMs(u64) void, interrupted() bool
//!
//! One iteration, in this order: (1) reap an exit; (2) while nothing has been
//! sent yet, look at the lease (observe), then beat when due; (3) once SIGTERM
//! is out, wait out the grace period, then force-stop; (4) sleep one poll.

const std = @import("std");

pub const Config = struct {
    /// TTL / 3.
    beat_every_ms: u64,
    grace_ms: u64,
    poll_ms: u64,
    /// After the forced stop, how long to wait for the process to be gone
    /// before reporting it stuck. systemctl's own stop timeout defaults to 90s.
    reap_ms: u64,
};

pub const Status = union(enum) {
    exited: u8,
    signaled: u32,

    pub fn ok(s: Status) bool {
        return s == .exited and s.exited == 0;
    }
};

/// `held`: the lease this run took is still the job's current lease.
/// `lost`: it is not; the words say how (preempted, hold, lease lapsed, ...).
pub const Lease = union(enum) { held, lost: []const u8 };

pub const Checkpoint = union(enum) { recorded, refused: []const u8 };

pub const Cause = enum { lease_lost, interrupted };

pub const Outcome = union(enum) {
    /// The process ended by itself and a checkpoint was attempted.
    finished: struct { status: Status, checkpoint: Checkpoint },
    /// The supervisor stopped the process; no checkpoint is attempted (the
    /// core would refuse it: the job is no longer running).
    stopped: struct { cause: Cause, why: []const u8, status: Status, forced: bool },
    /// The process was still alive `reap_ms` after the forced stop.
    stuck: struct { cause: Cause, why: []const u8 },
};

pub fn supervise(store: anytype, proc: anytype, env: anytype, cfg: Config) Outcome {
    const t0 = env.nowMs();
    var next_beat = t0 + cfg.beat_every_ms;
    var cause: ?Cause = null;
    var why: []const u8 = "";
    var termed_at: u64 = 0;
    var forced_at: ?u64 = null;
    while (true) {
        if (proc.poll()) |st| {
            if (cause) |c| return .{ .stopped = .{ .cause = c, .why = why, .status = st, .forced = forced_at != null } };
            return .{ .finished = .{ .status = st, .checkpoint = store.checkpoint() } };
        }
        const now = env.nowMs();
        if (cause == null) {
            if (env.interrupted()) {
                cause = .interrupted;
                why = "q run was interrupted";
            } else switch (store.observe()) {
                .lost => |w| {
                    cause = .lease_lost;
                    why = w;
                },
                .held => if (now >= next_beat) switch (store.beat()) {
                    .lost => |w| {
                        cause = .lease_lost;
                        why = w;
                    },
                    .held => next_beat = now + cfg.beat_every_ms,
                },
            }
            if (cause != null) {
                proc.term();
                termed_at = now;
            }
        } else if (forced_at == null) {
            if (now -| termed_at >= cfg.grace_ms) {
                proc.forceStop();
                forced_at = now;
            }
        } else if (now -| forced_at.? >= cfg.reap_ms) {
            return .{ .stuck = .{ .cause = cause.?, .why = why } };
        }
        env.sleepMs(cfg.poll_ms);
    }
}

// ------------------------------------------------------------------ fakes

const Fake = struct {
    // virtual clock: sleeping advances it, nothing really waits
    now: u64 = 0,
    // script
    exit_at: ?u64 = null, // the process exits on its own at this time
    exit_on_term: bool = false, // ... or as soon as it is signalled
    lease_lost_at: ?u64 = null, // observe() reports lost from here on
    lost_words: []const u8 = "preempted",
    ckpt_refuses: bool = false,
    int_at: ?u64 = null,
    // record
    beats: u32 = 0,
    ckpts: u32 = 0,
    observes: u32 = 0,
    termed: ?u64 = null,
    forced: ?u64 = null,
    gone_at: ?u64 = null,
    stubborn: bool = false, // ignores even the forced stop

    fn lostNow(f: *Fake) bool {
        return if (f.lease_lost_at) |at| f.now >= at else false;
    }
    // store
    pub fn observe(f: *Fake) Lease {
        f.observes += 1;
        return if (f.lostNow()) .{ .lost = f.lost_words } else .held;
    }
    pub fn beat(f: *Fake) Lease {
        if (f.lostNow()) return .{ .lost = f.lost_words };
        f.beats += 1;
        return .held;
    }
    pub fn checkpoint(f: *Fake) Checkpoint {
        f.ckpts += 1;
        return if (f.ckpt_refuses) .{ .refused = "not running" } else .recorded;
    }
    // proc
    pub fn poll(f: *Fake) ?Status {
        if (f.gone_at) |_| return .{ .signaled = 15 };
        if (f.exit_at) |at| if (f.now >= at) {
            f.gone_at = f.now;
            return .{ .exited = 0 };
        };
        if (f.exit_on_term and f.termed != null) {
            f.gone_at = f.now;
            return .{ .signaled = 15 };
        }
        if (f.forced != null and f.exit_at == null and !f.stubborn) {
            f.gone_at = f.now;
            return .{ .signaled = 9 };
        }
        return null;
    }
    pub fn term(f: *Fake) void {
        f.termed = f.now;
    }
    pub fn forceStop(f: *Fake) void {
        f.forced = f.now;
    }
    // env
    pub fn nowMs(f: *Fake) u64 {
        return f.now;
    }
    pub fn sleepMs(f: *Fake, ms: u64) void {
        if (f.now > 1_000_000) @panic("runaway supervisor loop: it never finished in 1000 virtual seconds");
        f.now += ms;
    }
    pub fn interrupted(f: *Fake) bool {
        return if (f.int_at) |at| f.now >= at else false;
    }
};

const tcfg = Config{ .beat_every_ms = 5_000, .grace_ms = 3_000, .poll_ms = 1_000, .reap_ms = 10_000 };
const t = std.testing;

fn go(f: *Fake) Outcome {
    return supervise(f, f, f, tcfg);
}

test "exit leads to exactly one checkpoint, after the beats that were due" {
    var f = Fake{ .exit_at = 12_000 };
    const o = go(&f);
    try t.expect(o == .finished);
    try t.expect(o.finished.status.ok());
    try t.expect(o.finished.checkpoint == .recorded);
    try t.expectEqual(@as(u32, 2), f.beats); // due at 5s and 10s
    try t.expectEqual(@as(u32, 1), f.ckpts);
    try t.expect(f.termed == null and f.forced == null);
}

test "a refused checkpoint is reported, not swallowed" {
    var f = Fake{ .exit_at = 2_000, .ckpt_refuses = true };
    const o = go(&f);
    try t.expectEqualStrings("not running", o.finished.checkpoint.refused);
}

test "preempt: SIGTERM at once, process leaves in grace, no force, no checkpoint" {
    var f = Fake{ .lease_lost_at = 4_000, .exit_on_term = true, .lost_words = "preempted" };
    const o = go(&f);
    try t.expect(o == .stopped);
    try t.expectEqual(Cause.lease_lost, o.stopped.cause);
    try t.expectEqualStrings("preempted", o.stopped.why);
    try t.expect(!o.stopped.forced);
    try t.expectEqual(@as(?u64, 4_000), f.termed);
    try t.expect(f.forced == null);
    try t.expectEqual(@as(u32, 0), f.ckpts);
    try t.expectEqual(@as(u32, 0), f.beats); // lost before the first beat was due
}

test "hold or lapse seen by the beat itself (observe saw nothing)" {
    // observe() only starts to report loss after the beat is due, so the
    // beat is what finds it, as when another q's tick lapsed the lease.
    const B = struct {
        f: Fake,
        pub fn observe(_: *@This()) Lease {
            return .held;
        }
        pub fn beat(_: *@This()) Lease {
            return .{ .lost = "lease expired" };
        }
        pub fn checkpoint(s: *@This()) Checkpoint {
            s.f.ckpts += 1;
            return .recorded;
        }
    };
    var f = Fake{ .exit_on_term = true };
    var b = B{ .f = f };
    const o = supervise(&b, &f, &f, tcfg);
    try t.expectEqualStrings("lease expired", o.stopped.why);
    try t.expectEqual(@as(?u64, 5_000), f.termed);
    try t.expectEqual(@as(u32, 0), b.f.ckpts);
}

test "a process that ignores SIGTERM is force-stopped after the grace period" {
    var f = Fake{ .lease_lost_at = 0 };
    const o = go(&f);
    try t.expect(o.stopped.forced);
    try t.expectEqual(@as(?u64, 0), f.termed);
    try t.expectEqual(@as(?u64, 3_000), f.forced); // exactly grace_ms later
    try t.expectEqual(Status{ .signaled = 9 }, o.stopped.status);
}

test "a process that survives the force-stop is reported stuck" {
    var f = Fake{ .lease_lost_at = 0, .stubborn = true };
    const o = go(&f);
    try t.expect(o == .stuck);
    try t.expectEqual(@as(?u64, 3_000), f.forced);
    try t.expect(f.now >= 13_000);
}

test "interrupt behaves like a lost lease for the process, with its own cause" {
    var f = Fake{ .int_at = 2_500, .exit_on_term = true };
    const o = go(&f);
    try t.expectEqual(Cause.interrupted, o.stopped.cause);
    try t.expectEqual(@as(u32, 0), f.ckpts);
}

test "a process that exits while being stopped is not checkpointed" {
    // lease lost, SIGTERM sent, and it dies by itself in the same poll
    var f = Fake{ .lease_lost_at = 1_000, .exit_at = 1_000 };
    const o = go(&f);
    // exit was seen first at the 1s poll, before any loss was acted on:
    // that is a finish, and the checkpoint attempt is the core's to refuse.
    try t.expect(o == .finished);
    try t.expectEqual(@as(u32, 1), f.ckpts);
}
