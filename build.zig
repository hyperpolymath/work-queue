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
    const test_step = b.step("test", "Unit tests of the functional core and the shell");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Launching under limits (tier 2): argv plan, supervisor loop, Linux process side.
    // Independent of the store and of the core.
    const launch = b.createModule(.{
        .root_source_file = b.path("src/launch/launch.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = launch })).step);

    // The `q` CLI: the imperative shell around the core.
    const cli = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "queue", .module = queue },
            .{ .name = "launch", .module = launch },
        },
    });
    const q = b.addExecutable(.{ .name = "q", .root_module = cli });
    b.installArtifact(q);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli })).step);

    // Full-graph conformance against the TLC oracle (`just oracle` makes it).
    const dir = b.option([]const u8, "oracle-dir", "Directory holding oracle-drafted.txt, oracle-fix.txt and oracle-shares.txt") orelse
        ".oracle";
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "oracle-drafted.txt" }) }, "oracle-drafted.txt");
    _ = wf.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "oracle-fix.txt" }) }, "oracle-fix.txt");
    _ = wf.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ dir, "oracle-shares.txt" }) }, "oracle-shares.txt");
    const oracle_src = wf.add("oracle.zig",
        \\pub const drafted = @embedFile("oracle-drafted.txt");
        \\pub const fix = @embedFile("oracle-fix.txt");
        \\pub const shares = @embedFile("oracle-shares.txt");
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
