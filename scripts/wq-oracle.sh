#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Model-check the work-queue spec and rebuild the conformance oracles.
#   1. TLC on Safety, SafetyWithFix, LiveWithFix, SharesSafety, SharesLive
#      (all must pass)
#   2. TLC on LiveAsDrafted (must FAIL: it is the recorded counterexample)
#   3. Dump the three safety state graphs and convert them with oracle.awk
# Output: .oracle/oracle-{drafted,fix,shares}.txt (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
spec=verification/proofs/tlaplus/workqueue
root=$PWD
out=$root/.oracle
jar=$out/tla2tools.jar
url=https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
sha=7e53aa636dac8a3cb0533f343115c0548e03fc0ce5edc7739becf58d3d0fb84f
mkdir -p "$out"
if [ ! -f "$jar" ]; then curl -fsSL -o "$jar" "$url"; fi
echo "$sha  $jar" | sha256sum -c --quiet || { echo "tla2tools.jar checksum mismatch" >&2; exit 1; }
meta=$(mktemp -d); trap 'rm -rf "$meta"' EXIT
tlc() { java -XX:+UseParallelGC -jar "$jar" -workers auto -deadlock -noGenerateSpecTE -metadir "$meta/$1" -config "$1.cfg" "${@:2}" MC.tla; }

cd "$spec"
for c in Safety SafetyWithFix LiveWithFix SharesSafety SharesLive; do
  tlc "$c" > "$meta/$c.log" 2>&1 || { tail -40 "$meta/$c.log"; echo "TLC FAILED: $c" >&2; exit 1; }
  echo "pass  $c: $(grep -E '^[0-9]+ states generated' "$meta/$c.log" | tail -1)"
done
if tlc LiveAsDrafted > "$meta/lad.log" 2>&1; then
  echo "LiveAsDrafted unexpectedly passed: the recorded counterexample is gone" >&2; exit 1
fi
# TLC names the properties its one reported lasso violates. The finding is the
# endless reject loop, which always breaks Terminates; NoStarvation may or may
# not be named, depending on which lasso TLC reports.
grep -qE 'Temporal propert(y|ies) (.* )?Terminates( .*)? (was|were) violated' "$meta/lad.log" \
  || { tail -40 "$meta/lad.log"; echo "LiveAsDrafted failed for an unexpected reason" >&2; exit 1; }
echo "fail  LiveAsDrafted (expected): $(grep -E 'Temporal propert(y|ies) .* violated' "$meta/lad.log")"

tlc Safety -dump dot,actionlabels "$meta/drafted.dot" > /dev/null 2>&1
tlc SafetyWithFix -dump dot,actionlabels "$meta/fix.dot" > /dev/null 2>&1
awk -f oracle.awk "$meta/drafted.dot" > "$out/oracle-drafted.txt"
awk -f oracle.awk "$meta/fix.dot" > "$out/oracle-fix.txt"
tlc SharesSafety -dump dot,actionlabels "$meta/shares.dot" > /dev/null 2>&1
awk -v NJ=4 -f oracle.awk "$meta/shares.dot" > "$out/oracle-shares.txt"
