# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
# Convert a TLC state-graph dump (-dump dot,actionlabels) of MC.tla into the
# work-queue oracle format v1 (see README.adoc). POSIX awk (mawk-compatible).
#   S <n> <hostHold> then per job in Jobs order: st reason lease res measured rejects
#   I <n>                          initial state
#   E <from> <to> <Action> [args]  one labelled transition
# TLC wraps a long value onto further \n-separated lines; a line that does not
# open a new "/\ var = " conjunct continues the previous one.
function field(lbl, name,    i, n, parts, p, v, on) {
  n = split(lbl, parts, /\\n/); on = 0
  for (i = 1; i <= n; i++) {
    p = parts[i]
    if (p ~ /^\/\\\\ /) {
      if (on) return v
      sub(/^\/\\\\ /, "", p)
      if (index(p, name " = ") == 1) { on = 1; v = substr(p, length(name) + 4) }
    } else if (on) { sub(/^ +/, " ", p); v = v p }
  }
  if (on) return v
  print "oracle.awk: missing variable " name > "/dev/stderr"; exit 2
}
function perjob(v,    out, n, xs, i) {
  gsub(/\\"/, "", v); gsub(/^\[|\]$/, "", v)
  gsub(/j[0-9]+ \|-> /, "", v)
  n = split(v, xs, /, /)
  if (n != NJ) { print "oracle.awk: expected " NJ " jobs, got " n > "/dev/stderr"; exit 2 }
  for (i = 1; i <= n; i++) { gsub(/^ +| +$/, "", xs[i]); gsub(/ /, "_", xs[i]); out = out (i > 1 ? "\t" : "") xs[i] }
  return out
}
function idx(id) { if (!(id in IDX)) { IDX[id] = ++N } ; return IDX[id] }
BEGIN { if (NJ == "") NJ = 3; FS = "\n" }   # awk -v NJ=<jobs>
/^-?[0-9]+ \[label="/ {
  id = $0; sub(/ .*/, "", id)
  if (id in SEEN) next
  SEEN[id] = 1
  lbl = $0; sub(/^-?[0-9]+ \[label="/, "", lbl); sub(/",(style|tooltip).*$/, "", lbl)
  hh = field(lbl, "hostHold") == "TRUE" ? 1 : 0
  split(perjob(field(lbl, "st")), A, "\t");      split(perjob(field(lbl, "reason")), B, "\t")
  split(perjob(field(lbl, "lease")), C, "\t");   split(perjob(field(lbl, "res")), D, "\t")
  split(perjob(field(lbl, "measured")), F, "\t"); split(perjob(field(lbl, "rejects")), G, "\t")
  line = "S " idx(id) " " hh
  for (j = 1; j <= NJ; j++) line = line " " A[j] " " B[j] " " C[j] " " D[j] " " (F[j] == "TRUE" ? 1 : 0) " " G[j]
  print line
  if ($0 ~ /style = filled/) print "I " idx(id)
  next
}
/^-?[0-9]+ -> -?[0-9]+ \[label="/ {
  split($0, w, " "); a = w[1]; b = w[3]
  act = $0; sub(/^[^"]*"/, "", act); sub(/",color.*$/, "", act)
  gsub(/\\"/, "", act); gsub(/[(),]/, " ", act); gsub(/ +/, " ", act); sub(/ $/, "", act)
  print "E " idx(a) " " idx(b) " " act
  NE++
}
END { print "# states=" N " edges=" NE > "/dev/stderr" }
