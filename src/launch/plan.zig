// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Pure part of `q run`: what to execute, as argv arrays, and the dry-run text.
//!
//! Untrusted input. A job's `command` and `cwd` come from a job record that
//! anyone who can write the store can write. They are never spliced into a
//! shell string by q. The command travels as ONE argv element after
//! `/bin/sh -c`; it is a shell script by design (CONTRACT section 2 has
//! `a && b`), and sh is the only thing that interprets it. The `cwd` is never
//! put in a command line at all: it is set on the spawned process (chdir in the
//! child). Everything q itself builds into an argv (unit name, MemoryMax,
//! CPUQuota) comes from the id, validated here, and from numbers.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Limiter = enum { systemd, none };

pub const shell = "/bin/sh";

pub const Spec = struct {
    id: []const u8,
    command: []const u8,
    cwd: []const u8,
    /// MemoryMax, MiB: admission.resources.ram_gib exactly, rounded up to a
    /// whole MiB (the core's reservation rounds up to whole GiB; the limit
    /// does not).
    ram_mib: u64,
    /// CPUQuota percent (cpu * 100, rounded up); null when the record has no
    /// `cpu`, in which case no CPUQuota is set and q says so.
    cpu_pct: ?u32,
};

/// Why a spec must not be launched, or null. Checked before `start` is
/// written, so a refusal never leaves a lease behind.
pub fn problem(s: Spec) ?[]const u8 {
    if (!validUnitId(s.id)) return "the job id is not usable in a unit name";
    if (s.command.len == 0) return "admission.command is empty";
    if (std.mem.indexOfScalar(u8, s.command, 0) != null) return "admission.command contains a NUL byte";
    if (s.cwd.len == 0 or s.cwd[0] != '/') return "admission.cwd must be an absolute path";
    if (std.mem.indexOfScalar(u8, s.cwd, 0) != null) return "admission.cwd contains a NUL byte";
    if (s.ram_mib == 0) return "admission.resources.ram_gib is not set";
    return null;
}

/// Letters, digits and - _ . only; not starting with - or . (same rule as the
/// store's job ids; repeated here so this module is safe on its own).
pub fn validUnitId(id: []const u8) bool {
    if (id.len == 0 or id.len > 200) return false;
    if (id[0] == '-' or id[0] == '.') return false;
    for (id) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return true;
}

/// The argv that runs the job. `systemd`:
///   systemd-run --user --scope --unit wq-<id> -p MemoryMax=<n>M [-p CPUQuota=<n>%] -- /bin/sh -c <command>
/// `none`: /bin/sh -c <command>
pub fn runArgv(a: Allocator, s: Spec, lim: Limiter) Allocator.Error![]const []const u8 {
    var v: std.ArrayList([]const u8) = .empty;
    if (lim == .systemd) {
        try v.appendSlice(a, &.{ "systemd-run", "--user", "--scope", "--unit" });
        try v.append(a, try unitBase(a, s.id));
        try v.append(a, "-p");
        try v.append(a, try std.fmt.allocPrint(a, "MemoryMax={d}M", .{s.ram_mib}));
        if (s.cpu_pct) |p| {
            try v.append(a, "-p");
            try v.append(a, try std.fmt.allocPrint(a, "CPUQuota={d}%", .{p}));
        }
        try v.append(a, "--");
    }
    try v.appendSlice(a, &.{ shell, "-c", s.command });
    return v.items;
}

/// The force-stop for the systemd limiter: systemctl --user stop wq-<id>.scope
pub fn stopArgv(a: Allocator, s: Spec) Allocator.Error![]const []const u8 {
    return a.dupe([]const u8, &.{ "systemctl", "--user", "stop", try std.fmt.allocPrint(a, "wq-{s}.scope", .{s.id}) });
}

fn unitBase(a: Allocator, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "wq-{s}", .{id});
}

/// cpu * 100 as a whole percent, at least 1; null for no cpu.
pub fn cpuPercent(cpu: f64) u32 {
    const p = @ceil(cpu * 100.0);
    return if (p < 1) 1 else if (p > 1_000_000) 1_000_000 else @intFromFloat(p);
}

pub fn ramMib(gib: f64) u64 {
    if (!(gib > 0)) return 0;
    const m = @ceil(gib * 1024.0);
    return if (m < 1) 1 else if (m > 1 << 30) 1 << 30 else @intFromFloat(m);
}

/// Does a cgroup.controllers file list both `memory` and `cpu`? Without them
/// delegated to the user manager, systemd accepts MemoryMax and CPUQuota and
/// silently enforces nothing. The shell reads
/// /sys/fs/cgroup/user.slice/user-<uid>.slice/user@<uid>.service/cgroup.controllers
/// and refuses to launch when this is false.
pub fn controllersOk(contents: []const u8) bool {
    var mem = false;
    var cpu = false;
    var it = std.mem.tokenizeAny(u8, contents, " \n");
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, "memory")) mem = true;
        if (std.mem.eql(u8, w, "cpu")) cpu = true;
    }
    return mem and cpu;
}

fn quoted(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31, 127 => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

pub const Timing = struct { beat_s: i64, grace_s: i64 };

/// The `--dry-run` text: exact argv, one JSON-quoted element per line, so a
/// newline or a quote in the command cannot blur it. `start_note` says whether
/// the core would enable `start` now.
pub fn dryRun(a: Allocator, w: *Writer, s: Spec, worker: []const u8, lim: Limiter, tm: Timing, start_note: []const u8) !void {
    try w.print("q run (dry run): nothing started, nothing written\njob {s}, worker {s}, limiter {t}\n", .{ s.id, worker, lim });
    try w.print("start: {s}\ncwd: ", .{start_note});
    try quoted(w, s.cwd);
    try w.writeByte('\n');
    for (try runArgv(a, s, lim), 0..) |x, i| {
        try w.print("argv[{d}]: ", .{i});
        try quoted(w, x);
        try w.writeByte('\n');
    }
    try w.print("heartbeat: beat every {d}s (lease TTL / 3)\ngrace: SIGTERM, then {d}s, then ", .{ tm.beat_s, tm.grace_s });
    switch (lim) {
        .systemd => {
            try w.writeAll("force stop:");
            for (try stopArgv(a, s)) |x| {
                try w.writeByte(' ');
                try quoted(w, x);
            }
            try w.writeByte('\n');
            if (s.cpu_pct == null) try w.writeAll("note: the record has no resources.cpu, so no CPUQuota is set\n");
        },
        .none => try w.writeAll("SIGKILL to the process group\nnote: --limiter none applies no memory or cpu limit\n"),
    }
}

const t = std.testing;

test "systemd argv is exactly the contract, command stays one element" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = Spec{ .id = "proof-a", .command = "a && b; $(touch /tmp/x) \"q\"", .cwd = "/srv/p", .ram_mib = 6144, .cpu_pct = 400 };
    const v = try runArgv(arena.allocator(), s, .systemd);
    const want = [_][]const u8{ "systemd-run", "--user", "--scope", "--unit", "wq-proof-a", "-p", "MemoryMax=6144M", "-p", "CPUQuota=400%", "--", "/bin/sh", "-c", "a && b; $(touch /tmp/x) \"q\"" };
    try t.expectEqual(want.len, v.len);
    for (want, v) |x, y| try t.expectEqualStrings(x, y);
}

test "none limiter and a record without cpu" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = Spec{ .id = "j", .command = "true", .cwd = "/", .ram_mib = 1, .cpu_pct = null };
    try t.expectEqual(@as(usize, 3), (try runArgv(arena.allocator(), s, .none)).len);
    const nc = try runArgv(arena.allocator(), s, .systemd);
    try t.expectEqual(@as(usize, 11), nc.len);
    for (nc) |x| try t.expect(!std.mem.startsWith(u8, x, "CPUQuota"));
    const st = try stopArgv(arena.allocator(), s);
    try t.expectEqualStrings("wq-j.scope", st[3]);
}

test "problem refuses untrusted shapes before anything starts" {
    const ok = Spec{ .id = "j", .command = "true", .cwd = "/x", .ram_mib = 1, .cpu_pct = 100 };
    try t.expect(problem(ok) == null);
    var b = ok;
    b.id = "-rf";
    try t.expect(problem(b) != null);
    b = ok;
    b.id = "a b";
    try t.expect(problem(b) != null);
    b = ok;
    b.id = "../x";
    try t.expect(problem(b) != null);
    b = ok;
    b.cwd = "relative";
    try t.expect(problem(b) != null);
    b = ok;
    b.command = "a\x00b";
    try t.expect(problem(b) != null);
    b = ok;
    b.command = "";
    try t.expect(problem(b) != null);
}

test "rounding and controllers" {
    try t.expectEqual(@as(u64, 6144), ramMib(6));
    try t.expectEqual(@as(u64, 513), ramMib(0.5001));
    try t.expectEqual(@as(u32, 400), cpuPercent(4));
    try t.expectEqual(@as(u32, 150), cpuPercent(1.5));
    try t.expect(controllersOk("cpuset cpu io memory pids\n"));
    try t.expect(!controllersOk("cpu pids\n"));
    try t.expect(!controllersOk("cpuset memory\n")); // "cpuset" is not "cpu"
    try t.expect(!controllersOk(""));
}
