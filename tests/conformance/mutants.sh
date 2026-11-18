#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Mutation check for the conformance harness: plant one rule break at a time
# in src/core/queue.zig and require `zig build conformance` to FAIL on each.
# A mutant that survives means the oracle does not cover that rule.
set -euo pipefail
cd "$(dirname "$0")/../.."
src=src/core/queue.zig
bak=$(mktemp)
cp "$src" "$bak"
trap 'cp "$bak" "$src"; rm -f "$bak"' EXIT

mutants=(
  "admit ignores host hold|s/if (cur.st != .ready or self.host_hold or !self.fits(d, p, j)) return null;/if (cur.st != .ready or !self.fits(d, p, j)) return null;/"
  "admit ignores fit|s/if (cur.st != .ready or self.host_hold or !self.fits(d, p, j)) return null;/if (cur.st != .ready or self.host_hold) return null;/"
  "admit ignores priority|s/if (k.st == .ready and d\[ki\].prio < d\[j\].prio and self.fits(d, p, ki)) return null;/_ = ki;/"
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
  "hold keeps lease|0,/nj.reason = .held_by_owner;/s//nj.reason = .held_by_owner; nj.lease = cur.lease;/"
)

killed=0 survived=0
for m in "${mutants[@]}"; do
  name=${m%%|*} expr=${m#*|}
  cp "$bak" "$src"
  sed -i "$expr" "$src"
  if cmp -s "$bak" "$src"; then echo "NOT APPLIED  $name"; exit 2; fi
  if zig build conformance >/dev/null 2>&1; then
    echo "SURVIVED     $name"; survived=$((survived + 1))
  else
    echo "killed       $name"; killed=$((killed + 1))
  fi
done
echo "mutants: ${#mutants[@]}, killed: $killed, survived: $survived"
[ "$survived" -eq 0 ]
