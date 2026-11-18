#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# `q run` against REAL processes with `--limiter none`: no cgroup, no systemd.
# What this proves: the composition of start, beat, checkpoint and lease_lapse
# in the log; SIGTERM, grace and forced stop on preempt, hold, lease lapse and
# interrupt; refusals that write nothing. What it does NOT prove: that
# MemoryMax or CPUQuota are enforced. That is tests/cli/cgroup-acceptance.sh,
# which needs a Linux host with a systemd user session, and is not run here.
# Usage: tests/cli/run.sh   (needs zig-out/bin/q, jq, pgrep)
set -uo pipefail
cd "$(dirname "$0")/../.."
q=$PWD/zig-out/bin/q
[ -x "$q" ] || { echo "run.sh: build q first (zig build)" >&2; exit 2; }
for t in jq pgrep; do command -v $t >/dev/null || { echo "run.sh: $t is required" >&2; exit 2; }; done
tmp=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok       $1"; }
bad() { echo "FAILED   $1"; fail=1; }
expect() { # name, got, want
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}

# fresh <name>: a scratch store, TTL 3s so the beat is every second
fresh() {
  export WQ_HOME=$tmp/$1/home work=$tmp/$1/work
  mkdir -p "$work"
  unset WQ_NOW
  cat >"$tmp/host.toml" <<'EOF'
capacity_gib = 8
heavy_slots  = 2
probe_gib    = 2
reject_limit = 2
workers      = 2
lease_ttl    = "3s"
[shares]
work = 1
EOF
  "$q" host amend "$tmp/host.toml" >/dev/null
}
# job <id> <priority> <checkpoint> <command...>   (command as a TOML literal string)
job() {
  local id=$1 pri=$2 ck=$3; shift 3
  cat >"$tmp/$id.toml" <<EOF
id = "$id"
title = "$id"
category = "work"
priority = $pri
owner = "test"
[admission]
purpose = "test"
command = '$*'
cwd = "${CWD:-$work}"
ownership = "test"
resources = { ram_gib = 1, cpu = 1, measured = false }
duration = "10m"
checkpoint = "$ck"
accept = "test"
EOF
  "$q" add "$tmp/$id.toml" >/dev/null && "$q" record "$id" >/dev/null || return 1
  [ "${UPTO:-admit}" = record ] || "$q" admit "$id" >/dev/null
}
acts() { jq -r --arg j "$1" 'select(.job==$j).action' "$WQ_HOME/events.jsonl" | tr '\n' ' ' | sed 's/ $//'; }
state() { "$q" board --json | jq -r --arg j "$1" '.jobs[]|select(.id==$j).state'; }
waitfor() { # job state [seconds]
  local i; for ((i = 0; i < ${3:-20} * 10; i++)); do [ "$(state "$1")" = "$2" ] && return 0; sleep 0.1; done; return 1
}
gone() { # marker: no process whose command line holds it
  local i; for ((i = 0; i < 50; i++)); do pgrep -f -- "$1" >/dev/null || return 0; sleep 0.1; done; return 1
}

echo "== A: runs to the end: start, beats, one checkpoint; q run exits 0"
fresh a; job a 2 "git stash" 'echo from-the-job; sleep 4'
out=$("$q" run a --worker w1 --limiter none 2>/dev/null); rc=$?
expect "A exit code" "$rc" 0
case $out in *"exited with status 0"*) ok "A says how it ended";; *) bad "A output: $out";; esac
seq=$(acts a); case $seq in "add record admit start beat"*" checkpoint") ok "A log: $seq";; *) bad "A log: $seq";; esac
expect "A state" "$(state a)" checkpoint

echo "== B: a failing job is checkpointed and flagged (exit 4), not swallowed"
fresh b; job b 2 "git stash" 'exit 7'
out=$("$q" run b --worker w1 --limiter none 2>&1); rc=$?
expect "B exit code" "$rc" 4
case $out in *"exited with status 7"*) ok "B reports status 7";; *) bad "B output: $out";; esac
expect "B state" "$(state b)" checkpoint

echo "== C: preempt: SIGTERM, process leaves, no checkpoint"
fresh c; job c-low 3 "git stash" 'exec sleep 61.5'
"$q" run c-low --worker w1 --limiter none >"$tmp/c.out" 2>&1 & qp=$!
waitfor c-low running || bad "C never reached running"
UPTO=record job c-urgent 1 "git stash" 'true'
"$q" preempt c-low >/dev/null || bad "C preempt refused"
wait $qp; rc=$?
expect "C exit code" "$rc" 4
gone "sleep 61.5" && ok "C process is gone" || bad "C process survived"
seq=$(acts c-low); case $seq in *"start"*"preempt") ok "C log: $seq";; *) bad "C log: $seq";; esac
grep -q "preempted" "$tmp/c.out" && ok "C says preempted" || bad "C output: $(cat "$tmp/c.out")"
case $seq in *checkpoint*) bad "C wrote a checkpoint";; *) ok "C wrote no checkpoint";; esac

echo "== D: hold; a process that ignores SIGTERM is force-stopped after --grace"
fresh d; job d 2 "git stash" 'trap "" TERM; while :; do sleep 0.2; done  # marker-d-ignores-term'
t0=$SECONDS
"$q" run d --worker w1 --limiter none --grace 2s >"$tmp/d.out" 2>&1 & qp=$!
waitfor d running || bad "D never reached running"
"$q" hold d >/dev/null
wait $qp; rc=$?
expect "D exit code" "$rc" 4
gone "marker-d-ignores-term" && ok "D process is gone" || bad "D process survived"
grep -q "forced stop" "$tmp/d.out" && ok "D says it was forced" || bad "D output: $(cat "$tmp/d.out")"
[ $((SECONDS - t0)) -ge 2 ] && ok "D waited the grace period" || bad "D did not wait"
case $(acts d) in *"start"*"hold") ok "D log: $(acts d)";; *) bad "D log: $(acts d)";; esac

echo "== E: lease lapse while q run is stalled: the next beat finds it, process stopped"
fresh e; job e 2 "git stash" 'exec sleep 62.5'
"$q" run e --worker w1 --limiter none >"$tmp/e.out" 2>&1 & qp=$!
waitfor e running || bad "E never reached running"
kill -STOP $qp; sleep 4.5                      # longer than the 3s TTL
"$q" tick >/dev/null                           # someone else's tick lapses it
expect "E state while stalled" "$(state e)" held
kill -CONT $qp; wait $qp; rc=$?
expect "E exit code" "$rc" 4
gone "sleep 62.5" && ok "E process is gone" || bad "E process survived"
grep -q "lease expired" "$tmp/e.out" && ok "E says lease expired" || bad "E output: $(cat "$tmp/e.out")"
case $(acts e) in *"lease_lapse") ok "E log: $(acts e)";; *) bad "E log: $(acts e)";; esac

echo "== F: SIGTERM to q run: the job is stopped and held, not left running unwatched"
fresh f; job f 2 "git stash" 'exec sleep 63.5'
"$q" run f --worker w1 --limiter none >"$tmp/f.out" 2>&1 & qp=$!
waitfor f running || bad "F never reached running"
kill -TERM $qp; wait $qp; rc=$?
expect "F exit code" "$rc" 4
gone "sleep 63.5" && ok "F process is gone" || bad "F process survived"
expect "F state" "$(state f)" held

echo "== G: refusals write nothing"
lines() { wc -l <"$WQ_HOME/events.jsonl"; }
fresh g1; job g1 2 "git stash" 'true'; n=$(lines)
"$q" run g1 --worker w9 --limiter none >/dev/null 2>&1; expect "G unknown worker exits 3" "$?" 3
"$q" run nosuch --worker w1 --limiter none >/dev/null 2>&1; expect "G unknown job exits 3" "$?" 3
expect "G log untouched by both" "$(lines)" "$n"
fresh g2; CWD=relative/dir job g2 2 "git stash" 'true'; n=$(lines)
"$q" run g2 --worker w1 --limiter none >/dev/null 2>&1; expect "G relative cwd exits 3" "$?" 3
expect "G log untouched by it" "$(lines)" "$n"
fresh g3; job g3 2 "git stash" 'true'
"$q" run g3 --worker w1 --limiter none >/dev/null 2>&1; n=$(lines)
"$q" run g3 --worker w1 --limiter none >/dev/null 2>&1; expect "G second run of a checkpointed job exits 3" "$?" 3
expect "G log untouched by it too" "$(lines)" "$n"

echo "== H: --limiter systemd with no user session fails loudly before start"
if systemctl --user show --property=Version >/dev/null 2>&1; then
  echo "SKIPPED  H: this host has a systemd user manager; the negative case cannot be shown here"
else
  fresh h; job h 2 "git stash" 'true'
  n=$(wc -l <"$WQ_HOME/events.jsonl")
  err=$("$q" run h --worker w1 2>&1 >/dev/null); rc=$?
  expect "H exit code" "$rc" 1
  case $err in *"no limits can be enforced here"*"Nothing was started"*) ok "H says so";; *) bad "H stderr: $err";; esac
  expect "H log untouched" "$(wc -l <"$WQ_HOME/events.jsonl")" "$n"
fi

[ "$fail" = 0 ] && echo "run.sh: all checks pass" || { echo "run.sh: FAILED" >&2; exit 1; }
