#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Mutation check for the supervisor loop (src/launch/supervisor.zig): break one
# line at a time and require its fake-limiter tests to FAIL. Same rule as
# tests/conformance/mutants.sh: the unmodified file must pass first, and a
# mutant that does not compile is INVALID (exit 2), never a kill.
# Uses perl -0 because several mutants span two lines.
set -euo pipefail
cd "$(dirname "$0")/../.."
src=src/launch/supervisor.zig
bak=$(mktemp); cp "$src" "$bak"; trap 'cp "$bak" "$src"; rm -f "$bak"' EXIT
work=$(mktemp -d)
t() { (cd "$work" && timeout 120 zig test "$OLDPWD/src/launch/launch.zig" 2>&1) || true; }
pass_re='All [0-9]+ tests passed'
out=$(t)
grep -qE "$pass_re" <<<"$out" || { echo "baseline: the unmodified supervisor does not pass" >&2; exit 2; }
echo "baseline     unmodified supervisor passes"
mutants=(
  "grace ignored (force stop at once)|s/now -\| termed_at >= cfg.grace_ms/true/"
  "never beats|s/\.held => if \(now >= next_beat\)/.held => if (false)/"
  "beat deadline never advances|s/\.held => next_beat = now \+ cfg.beat_every_ms,/.held => next_beat = t0 + cfg.beat_every_ms,/"
  "no checkpoint on finish|s/\.checkpoint = store.checkpoint\(\)/.checkpoint = .recorded/"
  "a stopped process is checkpointed|s/(            if \(cause\) \|c\| return \.\{ \.stopped)/            if (cause) |_| return .{ .finished = .{ .status = st, .checkpoint = store.checkpoint() } };\n\$1/"
  "never force-stops|s/proc.forceStop\(\);\n                forced_at = now;/forced_at = now;/"
  "no SIGTERM on loss|s/            if \(cause != null\) \{\n                proc.term\(\);/            if (cause != null) {/"
  "interrupt ignored|s/if \(env.interrupted\(\)\) \{/if (false) {/"
  "a stuck process is never reported|s/now -\| forced_at.\? >= cfg.reap_ms/false/"
  "a loss seen by observe is ignored|s/\} else switch \(store.observe\(\)\) \{\n                \.lost => \|w\| \{/} else switch (store.observe()) {\n                .lost => |w| if (false) {/"
)
killed=0 survived=0 invalid=0
for m in "${mutants[@]}"; do
  name=${m%%|*} expr=${m#*|}
  cp "$bak" "$src"; perl -0pi -e "$expr" "$src"
  if cmp -s "$src" "$bak"; then echo "INVALID      $name (the edit did not apply)"; invalid=$((invalid + 1)); continue; fi
  out=$(t)
  if grep -qE "$pass_re" <<<"$out"; then echo "SURVIVED     $name"; survived=$((survived + 1))
  elif grep -qE '^[^ ]+\.zig:[0-9]+:[0-9]+: error:' <<<"$out"; then echo "INVALID      $name (does not compile)"; invalid=$((invalid + 1))
  elif grep -qE 'failed|ABRT|panic' <<<"$out"; then echo "killed       $name"; killed=$((killed + 1))
  else echo "INVALID      $name (no clear result)"; invalid=$((invalid + 1)); fi
done
echo "launch mutants: ${#mutants[@]}, killed: $killed, survived: $survived, invalid: $invalid"
[ "$survived" = 0 ] && [ "$invalid" = 0 ]
