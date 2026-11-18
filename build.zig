// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const queue = b.createModule(.{
        .root_source_file = b.path("src/core/queue.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit = b.addTest(.{ .root_module = queue });
    const test_step = b.step("test", "Unit tests of the functional core");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Full-graph conformance against the TLC oracle (`just oracle` makes it).
    const dir = b.option([]const u8, "oracle-dir", "Directory holding oracle-drafted.txt and oracle-fix.txt") orelse
        ".oracle";
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "oracle-drafted.txt" }) }, "oracle-drafted.txt");
    _ = wf.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "oracle-fix.txt" }) }, "oracle-fix.txt");
    const oracle_src = wf.add("oracle.zig",
        \\pub const drafted = @embedFile("oracle-drafted.txt");
        \\pub const fix = @embedFile("oracle-fix.txt");
        \\
    );
    const oracle = b.createModule(.{ .root_source_file = oracle_src });

    const conf_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/conformance.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "queue", .module = queue },
            .{ .name = "oracle", .module = oracle },
        },
    });
    const conf = b.addTest(.{ .root_module = conf_mod });
    const conf_step = b.step("conformance", "Check the core against every TLC state and transition");
    conf_step.dependOn(&b.addRunArtifact(conf).step);
}
