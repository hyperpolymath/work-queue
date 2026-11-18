// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Full-graph conformance: the Zig core against every state and every
//! labelled transition TLC found for MC.tla, under Safety.cfg (contract as
//! drafted), SafetyWithFix.cfg (reject limit on, the MVP behaviour) and
//! SharesSafety.cfg (four jobs of one priority: the category-share tie-break).
//!   1. For every edge  s --A--> t :  step(s, A) == t
//!   2. For every state s :  the set of actions the core enables == the set
//!      of labelled edges leaving s in the graph (so no extra or missing moves)
//!   3. For every state s :  the core's own rule checks pass
//! The oracle text is produced by `just oracle` (TLC dump + oracle.awk).

const std = @import("std");
const core = @import("queue");
const oracles = @import("oracle");

// MC.tla constants, j1..j3 in TLC's record order.
const mc_decl = [3]core.Decl{
    .{ .need = 3, .heavy = true, .prio = 1, .ckpt = true, .obl = 1, .cat = 0 },
    .{ .need = 2, .heavy = true, .prio = 2, .ckpt = true, .obl = 2, .cat = 0 },
    .{ .need = 1, .heavy = false, .prio = 3, .ckpt = false, .obl = 2, .cat = 1 },
};
fn mcParams(bound: bool) core.Params {
    return .{ .cap = 4, .slots = 1, .probe_cap = 2, .max_rejects = 2, .use_reject_bound = bound, .workers = 2, .weights = &.{ 1, 1 } };
}

// MC.tla model 2 (SharesSafety.cfg): four light jobs of one priority; categories
// a = 0 (j1, j3, weight 2) and b = 1 (j2, j4, weight 1); j1 and j2 share an
// obligation.
const sh_decl = [4]core.Decl{
    .{ .need = 1, .heavy = false, .prio = 1, .ckpt = false, .obl = 1, .cat = 0 },
    .{ .need = 2, .heavy = false, .prio = 1, .ckpt = false, .obl = 1, .cat = 1 },
    .{ .need = 1, .heavy = false, .prio = 1, .ckpt = false, .obl = 3, .cat = 0 },
    .{ .need = 5, .heavy = false, .prio = 1, .ckpt = false, .obl = 4, .cat = 1 },
};
const sh_params = core.Params{ .cap = 6, .slots = 1, .probe_cap = 2, .max_rejects = 1, .use_reject_bound = true, .workers = 2, .weights = &.{ 2, 1 } };

const Mask = u256;

fn bit(a: core.Action) Mask {
    std.debug.assert(a.job < 4 and a.worker < 4);
    const i: u8 = @as(u8, @backingInt(a.tag)) * 16 + @as(u8, @intCast(a.job * 4 + a.worker));
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
        .{ "HostHoldOff", core.Tag.host_hold_off }, .{ "Beat", core.Tag.beat },
    };
    inline for (names) |p| if (std.mem.eql(u8, s, p[0])) return p[1];
    return null;
}

fn idxAfter(s: []const u8, prefix: u8) !u32 {
    if (s.len < 2 or s[0] != prefix) return error.BadName;
    return (try std.fmt.parseInt(u32, s[1..], 10)) - 1;
}

fn parseState(comptime Q: type, it: *std.mem.TokenIterator(u8, .scalar)) !Q {
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

fn conform(comptime n: usize, decl: *const [n]core.Decl, oracle: []const u8, params: core.Params, want_states: usize) !void {
    const Q = core.Queue(n);
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
        states.items[id - 1] = try parseState(Q, &it);
    }
    // The spec's Init must be exactly a fresh core queue.
    var inits: usize = 0;
    lines = std.mem.tokenizeScalar(u8, oracle, '\n');
    while (lines.next()) |line| {
        if (line[0] != 'I') continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next();
        const id = try std.fmt.parseInt(usize, it.next().?, 10);
        if (id == 0 or id > count) return error.BadStateId;
        if (!std.meta.eql(states.items[id - 1], Q{})) return error.InitialStateMismatch;
        inits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), inits);
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
        const got = states.items[from].step(decl, params, a) orelse {
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
        if (s.brokenRule(decl, params)) |rule| {
            std.debug.print("state {d} breaks {s}\n", .{ i + 1, rule });
            return error.RuleBroken;
        }
        var mine: Mask = 0;
        inline for (@typeInfo(core.Tag).@"enum".field_values) |fv| {
            const tag: core.Tag = @fromBackingInt(@intCast(fv));
            var jx: u32 = 0;
            while (jx < n) : (jx += 1) {
                var w: u32 = 0;
                while (w < params.workers) : (w += 1) {
                    const a = core.Action{
                        .tag = tag,
                        .job = if (tag == .host_hold_on or tag == .host_hold_off) 0 else jx,
                        .worker = if (tag == .start) w else 0,
                    };
                    if (s.step(decl, params, a) != null) mine |= bit(a);
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
    try conform(3, &mc_decl, oracles.drafted, mcParams(false), 70688);
}

test "conforms to the TLC graph, with the reject limit (MVP behaviour)" {
    try conform(3, &mc_decl, oracles.fix, mcParams(true), 38244);
}

test "conforms to the TLC graph of the category-share model" {
    try conform(4, &sh_decl, oracles.shares, sh_params, 217440);
}
