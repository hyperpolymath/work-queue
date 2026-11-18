#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# CLI golden tests for `q`, on a scratch $WQ_HOME with a frozen clock (WQ_NOW).
#   1. Run scenario.txt; the transcript (output and exit code of every
#      command), the final events.jsonl and the final board JSON must equal
#      golden/ byte for byte.
#   2. Replay: copy the store to a fresh $WQ_HOME; a new process folding the
#      log must print the same board.
#   3. The board JSON keeps the work-queue/board/v1 shape in TIERS.adoc (jq),
#      and every JSON output is I-JSON in JCS form (scripts/check-ijson-jcs.sh).
#   4. Negative controls: a log a guard refuses, and a torn append, exit 1.
# Usage: tests/cli/golden.sh [--update]   (needs zig-out/bin/q: `zig build`)
set -euo pipefail
cd "$(dirname "$0")/../.."
here=tests/cli
q=$PWD/zig-out/bin/q
[ -x "$q" ] || { echo "golden: build q first (zig build)" >&2; exit 2; }
command -v jq >/dev/null || { echo "golden: jq is required" >&2; exit 2; }
update=0; [ "${1:-}" = "--update" ] && update=1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
export WQ_HOME=$tmp/home

transcript=$tmp/transcript.txt
while IFS= read -r l; do
  case $l in ''|'#'*) continue ;; esac
  now=${l%% *} rest=${l#* }
  read -r -a args <<<"${rest//@\//$here/fixtures/}"
  printf '$ [%s] q %s\n' "$now" "$rest" >>"$transcript"
  set +e
  WQ_NOW=$now "$q" "${args[@]}" >>"$transcript" 2>&1; rc=$?
  set -e
  printf '[exit %d]\n' "$rc" >>"$transcript"
done <"$here/scenario.txt"
WQ_NOW=2026-11-18T10:00:00Z "$q" board --json >"$tmp/board.json"

check() { # name, produced file
  if [ "$update" = 1 ]; then cp "$2" "$here/golden/$1"; echo "updated  $1"
  elif cmp -s "$2" "$here/golden/$1"; then echo "same     $1"
  else echo "DIFFERS  $1"; diff -u "$here/golden/$1" "$2" | head -40; fail=1; fi
}
mkdir -p "$here/golden"
check transcript.txt "$transcript"
check events.jsonl "$WQ_HOME/events.jsonl"
check board.json "$tmp/board.json"

# 2. replay in a fresh home
cp -r "$WQ_HOME" "$tmp/replay"
WQ_HOME=$tmp/replay WQ_NOW=2026-11-18T10:00:00Z "$q" board --json >"$tmp/board2.json"
if cmp -s "$tmp/board.json" "$tmp/board2.json"; then echo "same     replayed board"; else echo "DIFFERS  replayed board"; fail=1; fi

# 3. shape (TIERS.adoc, board/v1) and I-JSON/JCS
shape='
  def only($ks): (keys == ($ks | sort));
  only(["categories","generated_at","host","jobs","schema"])
  and .schema == "work-queue/board/v1"
  and (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.host | only(["cap","heavy_running","hold","reserved","slots","workers"])
       and (.hold | type == "boolean") and ([.cap,.heavy_running,.reserved,.slots,.workers] | all(type == "number")))
  and (.categories | all(only(["name","share_target","share_used"])
       and (.share_target > 0 and .share_target <= 1) and (.share_used >= 0 and .share_used <= 1)))
  and (.jobs | all(only(["category","id","lease","line","measured","owner","priority","reason","rejects","res","state","title"])
       and (.line | test("^(Waiting|Held by|Progress): "))
       and ((.state == "running") == (.lease != null))
       and (.lease == null or (.lease | only(["expires_at","worker"])))
       and (.state | IN("queued","ready","admitted","running","checkpoint","held","completed","dropped"))))'
for b in "$tmp/board.json" "$here/golden/board.json"; do
  if jq -e "$shape" "$b" >/dev/null; then echo "shape ok $(basename "$b")"; else echo "BAD SHAPE $b"; fail=1; fi
done
mkdir -p "$tmp/json" && cp "$tmp/board.json" "$WQ_HOME/events.jsonl" "$tmp/json/"
./scripts/check-ijson-jcs.sh --enforce "$tmp/json" || fail=1

# 4. negative controls: the log must not fold
neg() { # name, sed expression
  rm -rf "$tmp/neg"; cp -r "$WQ_HOME" "$tmp/neg"; sed -i "$2" "$tmp/neg/events.jsonl"
  set +e; WQ_HOME=$tmp/neg WQ_NOW=2026-11-18T10:00:00Z "$q" board >/dev/null 2>"$tmp/neg.err"; rc=$?; set -e
  if [ "$rc" = 1 ]; then echo "exit 1   $1: $(cat "$tmp/neg.err")"; else echo "EXIT $rc  $1 (want 1)"; fail=1; fi
}
neg "an accept before any checkpoint (the core refuses it)" '0,/"action":"checkpoint"/s//"action":"accept"/'
neg "a torn append" '$ s/}$//'
neg "a sequence gap" '3d'

[ "$fail" = 0 ] && echo "golden: all checks pass" || { echo "golden: FAILED" >&2; exit 1; }
