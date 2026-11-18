// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//! Launching under limits (tier 2). Pure plan, generic supervisor, Linux
//! process side. Nothing here touches the store or the core.
pub const plan = @import("plan.zig");
pub const supervisor = @import("supervisor.zig");
pub const proc = @import("proc.zig");

test {
    _ = plan;
    _ = supervisor;
    _ = proc;
}
