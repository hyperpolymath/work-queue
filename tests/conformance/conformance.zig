// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Full-graph conformance: the Zig core against every state and every
//! labelled transition TLC found for MC.tla, under both Safety.cfg (contract
//! as drafted) and SafetyWithFix.cfg (reject limit on, the MVP behaviour).
//!   1. For every edge  s --A--> t :  step(s, A) == t
//!   2. For every state s :  the set of actions the core enables == the set
//!      of labelled edges leaving s in the graph (so no extra or missing moves)
//!   3. For every state s :  the core's own rule checks pass
//! The oracle text is produced by `just oracle` (TLC dump + oracle.awk).

const std = @import("std");
const core = @import("queue");
const oracles = @import("oracle");

const NJ = 3;
const Q = core.Queue(NJ);

// MC.tla constants, j1..j3 in TLC's record order.
const decl = [NJ]core.Decl{
    .{ .need = 3, .heavy = true, .prio = 1, .ckpt = true, .obl = 1 },
    .{ .need = 2, .heavy = true, .prio = 2, .ckpt = true, .obl = 2 },
    .{ .need = 1, .heavy = false, .prio = 3, .ckpt = false, .obl = 2 },
};
fn mcParams(bound: bool) core.Params {
    return .{ .cap = 4, .slots = 1, .probe_cap = 2, .max_rejects = 2, .use_reject_bound = bound, .workers = 2 };
}

const Mask = u256;

fn bit(a: core.Action) Mask {
    const i: u8 = @as(u8, @backingInt(a.tag)) * 16 + a.job * 4 + a.worker;
    return @as(Mask, 1) << i;
}

fn parseTag(s: []const u8) ?core.Tag {
    const names = .{
        .{ "Record", core.Tag.record },             .{ "Admit", core.Tag.admit },
        .{ "Start", core.Tag.start },               .{ "LeaseLapse", core.Tag.lease_lapse },
        .{ "Checkpoint", core.Tag.checkpoint },     .{ "Accept", core.Tag.accept },
        .{ "Reject", core.Tag.reject },             .{ "Preempt", core.Tag.preempt },
        .{ "Hold", core.Tag.hold },                 .{ "Release", core.Tag.release },
        .{ "Drop", core.Tag.drop },                 .{ "HostHoldOn", core.Tag.host_hold_on },
        .{ "HostHoldOff", core.Tag.host_hold_off },
    };
    inline for (names) |p| if (std.mem.eql(u8, s, p[0])) return p[1];
    return null;
}

fn idxAfter(s: []const u8, prefix: u8) !u8 {
    if (s.len < 2 or s[0] != prefix) return error.BadName;
    return (try std.fmt.parseInt(u8, s[1..], 10)) - 1;
}

fn parseState(it: *std.mem.TokenIterator(u8, .scalar)) !Q {
    var q = Q{};
    q.host_hold = std.mem.eql(u8, it.next().?, "1");
    for (&q.jobs) |*j| {
        j.st = std.meta.stringToEnum(core.St, it.next().?) orelse return error.BadSt;
        j.reason = std.meta.stringToEnum(core.Reason, it.next().?) orelse return error.BadReason;
        const l = it.next().?;
        j.lease = if (std.mem.eql(u8, l, "none")) core.no_worker else try idxAfter(l, 'w');
        j.res = try std.fmt.parseInt(u32, it.next().?, 10);
        j.measured = std.mem.eql(u8, it.next().?, "1");
        j.rejects = try std.fmt.parseInt(u8, it.next().?, 10);
    }
    return q;
}

fn conform(oracle: []const u8, params: core.Params, want_states: usize) !void {
    const gpa = std.testing.allocator;
    var states: std.ArrayList(Q) = .empty;
    defer states.deinit(gpa);
    var masks: std.ArrayList(Mask) = .empty;
    defer masks.deinit(gpa);

    // Pass 1: states, indexed by their oracle id (1-based; ids are dense but
    // not in file order, because an edge can name a state before its S line).
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, oracle, '\n');
    while (lines.next()) |line| {
        if (line[0] == 'S') count += 1;
    }
    try states.resize(gpa, count);
    try masks.appendNTimes(gpa, 0, count);
    var seen = try std.DynamicBitSet.initEmpty(gpa, count);
    defer seen.deinit();
    lines = std.mem.tokenizeScalar(u8, oracle, '\n');
    while (lines.next()) |line| {
        if (line[0] != 'S') continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next();
        const id = try std.fmt.parseInt(usize, it.next().?, 10);
        if (id == 0 or id > count or seen.isSet(id - 1)) return error.BadStateId;
        seen.set(id - 1);
        states.items[id - 1] = try parseState(&it);
    }
    // Pass 2: edges.
    var edges: usize = 0;
    var stutters: usize = 0;
    lines = std.mem.tokenizeScalar(u8, oracle, '\n');
    while (lines.next()) |line| {
        if (line[0] != 'E') continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next();
        const from = try std.fmt.parseInt(usize, it.next().?, 10) - 1;
        const to = try std.fmt.parseInt(usize, it.next().?, 10) - 1;
        const name = it.next().?;
        if (std.mem.eql(u8, name, "Next")) { // Done-state stutter: no core action
            try std.testing.expectEqual(from, to);
            stutters += 1;
            continue;
        }
        var a = core.Action{ .tag = parseTag(name) orelse return error.UnknownAction };
        if (it.next()) |js| a.job = try idxAfter(js, 'j');
        if (it.next()) |ws| a.worker = try idxAfter(ws, 'w');
        const got = states.items[from].step(&decl, params, a) orelse {
            std.debug.print("core refuses {s} at state {d}\n", .{ line, from + 1 });
            return error.MissingTransition;
        };
        if (!std.meta.eql(got, states.items[to])) {
            std.debug.print("wrong successor for {s}\n", .{line});
            return error.WrongSuccessor;
        }
        masks.items[from] |= bit(a);
        edges += 1;
    }

    // Pass 3: no extra moves, and the rules hold everywhere.
    for (states.items, masks.items, 0..) |s, m, i| {
        if (s.brokenRule(&decl, params)) |rule| {
            std.debug.print("state {d} breaks {s}\n", .{ i + 1, rule });
            return error.RuleBroken;
        }
        var mine: Mask = 0;
        inline for (@typeInfo(core.Tag).@"enum".field_values) |fv| {
            const tag: core.Tag = @fromBackingInt(@intCast(fv));
            var jx: u8 = 0;
            while (jx < NJ) : (jx += 1) {
                var w: u8 = 0;
                while (w < params.workers) : (w += 1) {
                    const a = core.Action{
                        .tag = tag,
                        .job = if (tag == .host_hold_on or tag == .host_hold_off) 0 else jx,
                        .worker = if (tag == .start) w else 0,
                    };
                    if (s.step(&decl, params, a) != null) mine |= bit(a);
                }
            }
        }
        if (mine != m) {
            std.debug.print("state {d}: core enables {x}, graph has {x}\n", .{ i + 1, mine, m });
            return error.EnabledSetMismatch;
        }
    }

    std.debug.print("conformance: {d} states, {d} transitions, {d} stutters, all match\n", .{ states.items.len, edges, stutters });
    try std.testing.expectEqual(want_states, states.items.len);
}

test "conforms to the TLC graph, contract as drafted (no reject limit)" {
    try conform(oracles.drafted, mcParams(false), 70688);
}

test "conforms to the TLC graph, with the reject limit (MVP behaviour)" {
    try conform(oracles.fix, mcParams(true), 38244);
}
