\* SPDX-License-Identifier: MPL-2.0
\* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--------------------------------- MODULE MC ---------------------------------
EXTENDS WorkQueue
(* Model 1, for the Safety and Live configs: three jobs, j1 urgent heavy, j2 normal heavy,   *)
(* j3 low light. j2 and j3 are duplicate captures of the same obligation.    *)
(* Priorities are distinct, so the share tie-break never decides here: this  *)
(* model must keep exactly its earlier state counts.                         *)
MCNeed   == [j \in Jobs |-> CASE j = "j1" -> 3 [] j = "j2" -> 2 [] OTHER -> 1]
MCHeavy  == [j \in Jobs |-> j # "j3"]
MCPrio   == [j \in Jobs |-> CASE j = "j1" -> 1 [] j = "j2" -> 2 [] OTHER -> 3]
MCCkpt   == [j \in Jobs |-> j # "j3"]
MCObl    == [j \in Jobs |-> IF j = "j1" THEN 1 ELSE 2]
MCCat    == [j \in Jobs |-> IF j = "j3" THEN "b" ELSE "a"]
MCWeight == [c \in {"a", "b"} |-> 1]

(* Model 2, for the Shares configs: four light jobs of one priority in two *)
(* categories, a = {j1, j3} with weight 2 and b = {j2, j4} with weight 1.    *)
(* Each conjunct of the share rule has a state where it alone decides:      *)
(*  - weights: j3 and j4 hold probes (a: 2/2, b: 2/1), so j1 goes before j2;  *)
(*  - rival ready and fits: j4, measured at 5 GiB, cannot fit beside j1, so   *)
(*    j3 is not held back by it;                                             *)
(*  - rival obligation free: j1 and j2 are captures of one obligation, so     *)
(*    while j1 runs, j2 cannot be admitted and must not hold back j3.        *)
SHNeed   == [j \in Jobs |-> CASE j \in {"j1", "j3"} -> 1 [] j = "j2" -> 2 [] OTHER -> 5]
SHHeavy  == [j \in Jobs |-> FALSE]
SHPrio   == [j \in Jobs |-> 1]
SHCkpt   == [j \in Jobs |-> FALSE]
SHObl    == [j \in Jobs |-> CASE j \in {"j1", "j2"} -> 1 [] j = "j3" -> 3 [] OTHER -> 4]
SHCat    == [j \in Jobs |-> IF j \in {"j1", "j3"} THEN "a" ELSE "b"]
SHWeight == [c \in {"a", "b"} |-> IF c = "a" THEN 2 ELSE 1]
=============================================================================
