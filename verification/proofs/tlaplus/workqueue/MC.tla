\* SPDX-License-Identifier: MPL-2.0
\* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--------------------------------- MODULE MC ---------------------------------
(* Three jobs: j1 urgent heavy, j2 normal heavy, j3 low light.              *)
(* j2 and j3 are duplicate captures of the same obligation.                 *)
EXTENDS WorkQueue
MCNeed  == [j \in Jobs |-> CASE j = "j1" -> 3 [] j = "j2" -> 2 [] OTHER -> 1]
MCHeavy == [j \in Jobs |-> j # "j3"]
MCPrio  == [j \in Jobs |-> CASE j = "j1" -> 1 [] j = "j2" -> 2 [] OTHER -> 3]
MCCkpt  == [j \in Jobs |-> j # "j3"]
MCObl   == [j \in Jobs |-> IF j = "j1" THEN 1 ELSE 2]
=============================================================================
