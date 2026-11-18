#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# The real cgroup acceptance run for `q run --limiter systemd`: a memory hog
# is killed at MemoryMax.
#
# NOT part of `just wq-cli` and NOT run in CI. It needs a Linux host with a
# systemd USER session and memory+cpu delegated to it, and it really allocates
# about 900 MiB for a moment (once under a 256 MiB limit, once as an unlimited
# control). Do not run it on a memory-starved host (not The-Titanic).
#
#   ./tests/cli/cgroup-acceptance.sh        (after `zig build`)
#
# Passing means: (1) with the limit, the hog is killed by SIGKILL and q run
# says so and exits 4 with a checkpoint recorded; (2) the same hog under
# `--limiter none` runs to the end with exit 0, so the limit, not the hog, was
# what changed the outcome. Exit 77 means the host cannot run it (SKIPPED).
set -uo pipefail
cd "$(dirname "$0")/../.."
q=$PWD/zig-out/bin/q
[ -x "$q" ] || { echo "cgroup-acceptance: build q first (zig build)" >&2; exit 2; }
if ! systemctl --user show --property=Version >/dev/null 2>&1; then
  echo "SKIPPED: no systemd user session on this host" >&2; exit 77
fi
uid=$(id -u)
ctl=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers
if ! grep -qw memory "$ctl" 2>/dev/null || ! grep -qw cpu "$ctl" 2>/dev/null; then
  echo "SKIPPED: memory and cpu are not delegated to your user manager ($ctl: $(cat "$ctl" 2>/dev/null))" >&2
  echo "         see systemd.resource-control(5), Delegate= in user@.service" >&2; exit 77
fi
tmp=$(mktemp -d); trap 'systemctl --user stop wq-hog.scope wq-ctl.scope 2>/dev/null; rm -rf "$tmp"' EXIT
export WQ_HOME=$tmp/home; mkdir -p "$tmp/work"
cat >"$tmp/host.toml" <<'EOF'
capacity_gib = 8
heavy_slots  = 2
probe_gib    = 2
reject_limit = 2
workers      = 2
lease_ttl    = "15m"
[shares]
work = 1
EOF
"$q" host amend "$tmp/host.toml" >/dev/null || exit 1
# 900 MiB on one line: sort has to hold all of it.
hog='head -c 900M /dev/zero | tr "\\0" a | sort >/dev/null'
mk() { # id ram_gib
  cat >"$tmp/$1.toml" <<EOF
id = "$1"
title = "$1"
category = "work"
priority = 2
owner = "test"
[admission]
purpose = "cgroup acceptance"
command = '$hog'
cwd = "$tmp/work"
ownership = "test"
resources = { ram_gib = $2, cpu = 1, measured = false }
duration = "10m"
checkpoint = "git stash"
accept = "test"
EOF
  "$q" add "$tmp/$1.toml" >/dev/null && "$q" record "$1" >/dev/null && "$q" admit "$1" >/dev/null
}
fail=0
mk hog 0.25; mk ctl 0.25   # both declare 256 MiB; only one is held to it
out=$("$q" run hog --worker w1 2>&1); rc=$?
echo "$out"
{ [ "$rc" = 4 ] && grep -q "killed by signal 9" <<<"$out"; } && echo "ok       hog killed at MemoryMax (exit 4, SIGKILL)" || { echo "FAILED   hog was not killed at MemoryMax (exit $rc)"; fail=1; }
"$q" run ctl --worker w2 --limiter none >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && echo "ok       the same hog runs to the end with no limit (control)" || { echo "FAILED   control did not complete (exit $rc): the hog itself is not usable on this host"; fail=1; }
[ "$fail" = 0 ] && echo "cgroup-acceptance: pass" || { echo "cgroup-acceptance: FAILED" >&2; exit 1; }
