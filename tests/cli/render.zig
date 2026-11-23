// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Test driver for the golden HTML tests: board JSON on stdin, page on stdout.
//! It is the renderer and nothing else (no store, no clock), so a fixture
//! board JSON can be fed in without building an event log for it.
//! Usage: render [--refresh <seconds>] < board.json > board.html
//! Exit 0 done, 2 usage, 1 the input is not a valid work-queue/board/v1 board.

const std = @import("std");
const html = @import("html");
const Io = std.Io;

pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = init.minimal.args.toSlice(arena) catch return 1;
    var opts: html.Options = .{};
    if (argv.len == 3 and std.mem.eql(u8, argv[1], "--refresh")) {
        opts.refresh_seconds = std.fmt.parseInt(u32, argv[2], 10) catch return 2;
    } else if (argv.len != 1) return 2;

    var ibuf: [4096]u8 = undefined;
    var ir = Io.File.stdin().reader(io, &ibuf);
    const json = ir.interface.allocRemaining(arena, .limited(16 << 20)) catch return 1;
    var obuf: [8192]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    html.render(arena, json, opts, &ow.interface) catch |e| {
        var ebuf: [128]u8 = undefined;
        var ew = Io.File.stderr().writer(io, &ebuf);
        ew.interface.print("render: {t}\n", .{e}) catch {};
        ew.interface.flush() catch {};
        return 1;
    };
    ow.interface.flush() catch return 1;
    return 0;
}
