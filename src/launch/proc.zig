// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! The real process side of `q run` (Linux). Spawns the argv from plan.zig in
//! its own process group, with `cwd` set on the child (never cd in a string),
//! and offers the three calls the supervisor needs: poll, term, forceStop.
//!
//! No resource limits are applied here; they are the `systemd-run` argv. For
//! `--limiter systemd` the child is systemd-run, which moves itself into the
//! transient scope and execs the command, so the process we signal is the
//! job's `sh` and everything it started in the same group; `forceStop` is
//! `systemctl --user stop wq-<id>.scope`, which also reaches processes that
//! left the group. For `--limiter none` the force stop is SIGKILL to the group.

const std = @import("std");
const builtin = @import("builtin");
const plan = @import("plan.zig");
const sup = @import("supervisor.zig");
const linux = std.os.linux;

pub const supported = builtin.os.tag == .linux;

pub const Proc = struct {
    io: std.Io,
    pid: i32,
    stopper: ?i32 = null, // pid of a running `systemctl stop`, reaped in poll
    limiter: plan.Limiter,
    stop_argv: []const []const u8,

    pub const SpawnError = std.process.SpawnError;

    pub fn start(io: std.Io, spec: plan.Spec, argv: []const []const u8, lim: plan.Limiter, stop_argv: []const []const u8) SpawnError!Proc {
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = spec.cwd },
            .pgid = 0, // its own process group: signals reach the job's tree, not q
        });
        return .{ .io = io, .pid = child.id.?, .limiter = lim, .stop_argv = stop_argv };
    }

    fn reap(pid: i32) ?u32 {
        var st: u32 = 0;
        while (true) {
            const rc = linux.waitpid(pid, @ptrCast(&st), linux.W.NOHANG);
            switch (linux.errno(rc)) {
                .SUCCESS => return if (rc == 0) null else st,
                .INTR => continue,
                else => return 0, // ECHILD: already gone; report a clean 0 exit
            }
        }
    }

    pub fn poll(p: *Proc) ?sup.Status {
        if (p.stopper) |sp| if (reap(sp) != null) {
            p.stopper = null;
        };
        const st = reap(p.pid) orelse return null;
        if (linux.W.IFEXITED(st)) return .{ .exited = linux.W.EXITSTATUS(st) };
        return .{ .signaled = @intFromEnum(linux.W.TERMSIG(st)) };
    }

    pub fn term(p: *Proc) void {
        _ = linux.kill(-p.pid, .TERM);
    }

    pub fn forceStop(p: *Proc) void {
        switch (p.limiter) {
            .none => _ = linux.kill(-p.pid, .KILL),
            .systemd => {
                // Not waited for here: systemctl may take its stop timeout, and
                // the supervisor keeps polling for the process to go.
                const c = std.process.spawn(p.io, .{ .argv = p.stop_argv }) catch return;
                p.stopper = c.id;
            },
        }
    }
};

// ---------------------------------------------------------- interruption

var interrupt_flag = std.atomic.Value(bool).init(false);

fn onSignal(_: linux.SIG) callconv(.c) void {
    interrupt_flag.store(true, .seq_cst);
}

/// Make SIGINT and SIGTERM to q itself request a stop instead of killing q
/// and leaving the job's process running with nobody to beat.
pub fn catchInterrupts() void {
    const act = linux.Sigaction{
        .handler = .{ .handler = &onSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.INT, &act, null);
    _ = linux.sigaction(.TERM, &act, null);
}

pub fn interrupted() bool {
    return interrupt_flag.load(.seq_cst);
}
