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


# 5. tier 3: the HTML board. Golden pages from fixture board JSON (the pure
#    renderer, wq-render), hostile input included; the page of the real store
#    is in transcript.txt (`board --html --out -`).
render=$PWD/zig-out/bin/wq-render
[ -x "$render" ] || { echo "golden: build wq-render first (zig build)" >&2; exit 2; }
mkdir -p "$here/html"
for n in full hostile; do
  "$render" <"$here/html/$n.board.json" >"$tmp/$n.html"
  check_html() { if [ "$update" = 1 ]; then cp "$2" "$here/html/$1"; echo "updated  html/$1"
    elif cmp -s "$2" "$here/html/$1"; then echo "same     html/$1"
    else echo "DIFFERS  html/$1"; diff -u "$here/html/$1" "$2" | head -40; fail=1; fi; }
  check_html "$n.html" "$tmp/$n.html"
done
"$render" --refresh 10 <"$here/html/full.board.json" >"$tmp/full-refresh.html"
check_html full-refresh.html "$tmp/full-refresh.html"
# hostile input must stay inert text: no script element, no handler attribute, no raw bidi override
if grep -Eq '<(script|img)|<[^>]* on[a-z]+=' "$tmp/hostile.html" || grep -q $'\xe2\x80\xae' "$tmp/hostile.html"; then
  echo "UNESCAPED hostile input in html/hostile.html"; fail=1; else echo "inert    hostile input"; fi
if "$render" <<<'{"schema":"work-queue/board/v2"}' >/dev/null 2>&1; then echo "ACCEPTED a bad schema"; fail=1; else echo "refused  a board with the wrong schema"; fi
# read-only: rendering the real store must not change events.jsonl or the job/host records
before=$(cd "$WQ_HOME" && find . -type f ! -name board.html -exec sha256sum {} + | sort)
WQ_NOW=2026-11-18T10:00:00Z "$q" board --html >"$tmp/wrote.txt"
after=$(cd "$WQ_HOME" && find . -type f ! -name board.html -exec sha256sum {} + | sort)
if [ "$before" = "$after" ] && [ -f "$WQ_HOME/board.html" ]; then echo "read-only board --html left the store untouched"; else echo "board --html CHANGED THE STORE"; fail=1; fi
# --watch: first page carries the refresh meta; an appended event regenerates it
set +e; WQ_NOW=2026-11-18T10:00:00Z "$q" board --html --watch --out "$tmp/live.html" >"$tmp/watch.out" 2>&1 & wpid=$!; set -e
for _ in $(seq 50); do [ -s "$tmp/live.html" ] && break; sleep 0.1; done
grep -q 'http-equiv="refresh"' "$tmp/live.html" && echo "watch    first page has the refresh meta" || { echo "watch: no refresh meta"; fail=1; }
cp "$tmp/live.html" "$tmp/live0.html"
WQ_NOW=2026-11-18T10:05:00Z "$q" host hold >/dev/null
changed=0; for _ in $(seq 60); do cmp -s "$tmp/live.html" "$tmp/live0.html" || { changed=1; break; }; sleep 0.1; done
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
if [ "$changed" = 1 ] && grep -q 'ON (no job is admitted)' "$tmp/live.html"; then echo "watch    page regenerated after the log changed"; else echo "watch: page did not regenerate"; fail=1; fi

# --refresh: 0 means a watched page without the meta; a bad use is a usage error (2)
set +e
WQ_NOW=2026-11-18T10:00:00Z "$q" board --html --watch --refresh 0 --out "$tmp/norefresh.html" >/dev/null 2>&1 & rpid=$!
for _ in $(seq 50); do [ -s "$tmp/norefresh.html" ] && break; sleep 0.1; done
kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
WQ_NOW=2026-11-18T10:00:00Z "$q" board --html --refresh 5 --out - >/dev/null 2>&1; rc1=$?
WQ_NOW=2026-11-18T10:00:00Z "$q" board --html --watch --refresh x --out "$tmp/x.html" >/dev/null 2>&1; rc2=$?
set -e
if [ -s "$tmp/norefresh.html" ] && ! grep -q 'http-equiv="refresh"' "$tmp/norefresh.html"; then echo "refresh  --refresh 0 leaves the meta out"; else echo "--refresh 0 still has the meta"; fail=1; fi
if [ "$rc1" = 2 ] && [ "$rc2" = 2 ]; then echo "exit 2   --refresh without --watch, and a non-number"; else echo "refresh usage errors gave $rc1 $rc2 (want 2 2)"; fail=1; fi

[ "$fail" = 0 ] && echo "golden: all checks pass" || { echo "golden: FAILED" >&2; exit 1; }
