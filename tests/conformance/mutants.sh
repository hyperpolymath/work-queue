#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Mutation check for the conformance harness: plant one rule break at a time
# in src/core/queue.zig and require `zig build conformance` to FAIL on each.
# A mutant that survives means the oracle does not cover that rule.
# Only a mutant that COMPILES and then fails conformance counts as killed:
# the unmodified core must pass first, and a mutant that does not compile is
# an invalid mutant (exit 2), never a kill. Logs: $WQ_MUTANT_LOGS (default a
# temp dir, printed at the end).
set -euo pipefail
cd "$(dirname "$0")/../.."
src=src/core/queue.zig
bak=$(mktemp)
cp "$src" "$bak"
logs=${WQ_MUTANT_LOGS:-$(mktemp -d)}
mkdir -p "$logs"
trap 'cp "$bak" "$src"; rm -f "$bak"' EXIT

# 1 = conformance ran and failed, 0 = passed, 2 = did not compile or could not run
run_conformance() {
  if zig build conformance >"$1" 2>&1; then return 0; fi
  if grep -qE 'compile test .*error|error: [0-9]+ compilation errors|: error: ' "$1"; then return 2; fi
  grep -qE 'tests? (passed|failed)|[0-9]+ fail' "$1" && return 1
  return 2
}

set +e
run_conformance "$logs/baseline.log"; rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "baseline conformance does not pass on the unmodified core (see $logs/baseline.log)" >&2
  exit 2
fi
echo "baseline     unmodified core passes conformance"

mutants=(
  "admit ignores host hold|s/if (cur.st != .ready or self.host_hold or !self.fits(d, p, j)) return null;/if (cur.st != .ready or !self.fits(d, p, j)) return null;/"
  "admit ignores fit|s/if (cur.st != .ready or self.host_hold or !self.fits(d, p, j)) return null;/if (cur.st != .ready or self.host_hold) return null;/"
  "admit ignores priority|s/if (k.st == .ready and d\[ki\].prio < d\[j\].prio and self.fits(d, p, ki)) return null;//"
  "admit ignores obligation|s/if (d\[ki\].obl == d\[j\].obl and isActive(k.st)) return null;//"
  "admit reserves need not probe|s/nj.res = self.sizeFor(d, p, j);/nj.res = d[j].need;/"
  "start ignores worker lease|s/for (self.jobs) |k| if (k.lease == a.worker) return null;//"
  "start off-by-one heavy slots|s/self.heavyRunning(d) >= p.slots/self.heavyRunning(d) > p.slots/"
  "lapse keeps reservation|0,/nj.reason = .lease_expired;/s//nj.reason = .lease_expired; nj.res = cur.res;/"
  "checkpoint forgets measurement|s/nj.measured = true;//"
  "reject not saturating|s/if (cur.rejects < p.max_rejects) nj.rejects = cur.rejects + 1;/nj.rejects = cur.rejects + 1;/"
  "reject limit off-by-one|s/@as(u32, cur.rejects) + 1 >= p.max_rejects/@as(u32, cur.rejects) + 1 > p.max_rejects/"
  "preempt ignores checkpointable|s/if (cur.st != .running or !d\[j\].ckpt) return null;/if (cur.st != .running) return null;/"
  "release frees reject-limited|s/if (cur.st != .held or cur.reason == .reject_limit) return null;/if (cur.st != .held) return null;/"
  "drop allowed while running|s/.queued, .ready, .held => {},/.queued, .ready, .held, .running => {},/"
  "beat allowed when not running|/\.beat => {/,/},/s/if (cur.st != .running) return null;//"
  "hold keeps lease|0,/nj.reason = .held_by_owner;/s//nj.reason = .held_by_owner; nj.lease = cur.lease;/"
)

killed=0 survived=0 invalid=0 i=0
for m in "${mutants[@]}"; do
  i=$((i + 1))
  name=${m%%|*} expr=${m#*|}
  cp "$bak" "$src"
  sed -i "$expr" "$src"
  if cmp -s "$bak" "$src"; then echo "NOT APPLIED  $name"; exit 2; fi
  set +e
  run_conformance "$logs/mutant-$i.log"; rc=$?
  set -e
  case $rc in
    0) echo "SURVIVED     $name"; survived=$((survived + 1)) ;;
    1) echo "killed       $name"; killed=$((killed + 1)) ;;
    *) echo "INVALID      $name (does not compile; $logs/mutant-$i.log)"; invalid=$((invalid + 1)) ;;
  esac
done
echo "mutants: ${#mutants[@]}, killed: $killed, survived: $survived, invalid: $invalid (logs: $logs)"
[ "$invalid" -eq 0 ] || exit 2
[ "$survived" -eq 0 ]
