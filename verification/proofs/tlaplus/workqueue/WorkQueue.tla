\* SPDX-License-Identifier: MPL-2.0
\* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
---------------------------- MODULE WorkQueue ----------------------------
(* Model of the job contract in CONTRACT.md, sections 3 and 4.            *)
(* States, leases, reservations, heavy slots, obligations, priorities.    *)
EXTENDS Naturals, FiniteSets

CONSTANTS Jobs, Workers, Cap, Slots, ProbeCap, MaxRejects,
          Need, Heavy, Prio, Ckpt, Obl, None,
          UseRejectBound    \* FALSE = contract as drafted, TRUE = proposed fix

VARIABLES st, reason, lease, res, measured, rejects, hostHold
vars == <<st, reason, lease, res, measured, rejects, hostHold>>

States  == {"queued","ready","admitted","running","checkpoint","held","completed","dropped"}
Active  == {"admitted","running","checkpoint"}
Reasons == {"none","no record","gate","awaiting start","validating",
            "lease expired","held by owner","preempted","reject limit"}

RECURSIVE SumRes(_)
SumRes(S) == IF S = {} THEN 0
             ELSE LET x == CHOOSE x \in S : TRUE IN res[x] + SumRes(S \ {x})

Reserved     == SumRes(Jobs)
Free         == Cap - Reserved
SizeFor(j)   == IF measured[j] THEN Need[j] ELSE ProbeCap
HeavyRunning == {j \in Jobs : st[j] = "running" /\ Heavy[j]}
Fits(j)      == SizeFor(j) <= Free

Init ==
  /\ st       = [j \in Jobs |-> "queued"]
  /\ reason   = [j \in Jobs |-> "no record"]
  /\ lease    = [j \in Jobs |-> None]
  /\ res      = [j \in Jobs |-> 0]
  /\ measured = [j \in Jobs |-> FALSE]
  /\ rejects  = [j \in Jobs |-> 0]
  /\ hostHold = FALSE

Record(j) ==
  /\ st[j] = "queued"
  /\ st' = [st EXCEPT ![j] = "ready"] /\ reason' = [reason EXCEPT ![j] = "gate"]
  /\ UNCHANGED <<lease, res, measured, rejects, hostHold>>

Admit(j) ==   \* rules 4, 5, 6 and the ownership check
  /\ st[j] = "ready" /\ ~hostHold /\ Fits(j)
  /\ ~\E k \in Jobs : k # j /\ st[k] = "ready" /\ Prio[k] < Prio[j] /\ Fits(k)
  /\ ~\E k \in Jobs : k # j /\ Obl[k] = Obl[j] /\ st[k] \in Active
  /\ st' = [st EXCEPT ![j] = "admitted"]
  /\ res' = [res EXCEPT ![j] = SizeFor(j)]
  /\ reason' = [reason EXCEPT ![j] = "awaiting start"]
  /\ UNCHANGED <<lease, measured, rejects, hostHold>>

Start(j, w) ==   \* rule 1
  /\ st[j] = "admitted"
  /\ \A k \in Jobs : lease[k] # w
  /\ Heavy[j] => Cardinality(HeavyRunning) < Slots
  /\ st' = [st EXCEPT ![j] = "running"] /\ lease' = [lease EXCEPT ![j] = w]
  /\ reason' = [reason EXCEPT ![j] = "none"]
  /\ UNCHANGED <<res, measured, rejects, hostHold>>

LeaseLapse(j) ==   \* rule 3
  /\ st[j] = "running"
  /\ st' = [st EXCEPT ![j] = "held"] /\ lease' = [lease EXCEPT ![j] = None]
  /\ res' = [res EXCEPT ![j] = 0] /\ reason' = [reason EXCEPT ![j] = "lease expired"]
  /\ UNCHANGED <<measured, rejects, hostHold>>

Checkpoint(j) ==   \* rule 6: probe measurement recorded
  /\ st[j] = "running"
  /\ st' = [st EXCEPT ![j] = "checkpoint"] /\ lease' = [lease EXCEPT ![j] = None]
  /\ measured' = [measured EXCEPT ![j] = TRUE]
  /\ reason' = [reason EXCEPT ![j] = "validating"]
  /\ UNCHANGED <<res, rejects, hostHold>>

Accept(j) ==
  /\ st[j] = "checkpoint"
  /\ st' = [st EXCEPT ![j] = "completed"] /\ res' = [res EXCEPT ![j] = 0]
  /\ reason' = [reason EXCEPT ![j] = "none"]
  /\ UNCHANGED <<lease, measured, rejects, hostHold>>

Reject(j) ==
  /\ st[j] = "checkpoint"
  /\ res' = [res EXCEPT ![j] = 0]
  \* Saturating counter: nothing reads rejects above MaxRejects, so this is a
  \* behaviour-preserving finite abstraction (lets TLC check liveness exactly).
  /\ rejects' = [rejects EXCEPT ![j] = IF @ < MaxRejects THEN @ + 1 ELSE @]
  /\ IF UseRejectBound /\ rejects[j] + 1 >= MaxRejects
       THEN /\ st' = [st EXCEPT ![j] = "held"]
            /\ reason' = [reason EXCEPT ![j] = "reject limit"]
       ELSE /\ st' = [st EXCEPT ![j] = "ready"]
            /\ reason' = [reason EXCEPT ![j] = "gate"]
  /\ UNCHANGED <<lease, measured, hostHold>>

Preempt(j) ==   \* rule 5: only checkpointable jobs, only for higher priority
  /\ st[j] = "running" /\ Ckpt[j]
  /\ \E k \in Jobs : st[k] = "ready" /\ Prio[k] < Prio[j]
  /\ st' = [st EXCEPT ![j] = "ready"] /\ lease' = [lease EXCEPT ![j] = None]
  /\ res' = [res EXCEPT ![j] = 0] /\ reason' = [reason EXCEPT ![j] = "preempted"]
  /\ UNCHANGED <<measured, rejects, hostHold>>

Hold(j) ==
  /\ st[j] \in {"ready","admitted","running","checkpoint"}
  /\ st' = [st EXCEPT ![j] = "held"] /\ lease' = [lease EXCEPT ![j] = None]
  /\ res' = [res EXCEPT ![j] = 0] /\ reason' = [reason EXCEPT ![j] = "held by owner"]
  /\ UNCHANGED <<measured, rejects, hostHold>>

Release(j) ==
  /\ st[j] = "held" /\ reason[j] # "reject limit"   \* reject-limited needs owner edit
  /\ st' = [st EXCEPT ![j] = "ready"] /\ reason' = [reason EXCEPT ![j] = "gate"]
  /\ UNCHANGED <<lease, res, measured, rejects, hostHold>>

Drop(j) ==
  /\ st[j] \in {"queued","ready","held"}
  /\ st' = [st EXCEPT ![j] = "dropped"] /\ res' = [res EXCEPT ![j] = 0]
  /\ reason' = [reason EXCEPT ![j] = "none"]
  /\ UNCHANGED <<lease, measured, rejects, hostHold>>

HostHoldOn  == ~hostHold /\ hostHold' = TRUE  /\ UNCHANGED <<st, reason, lease, res, measured, rejects>>
HostHoldOff ==  hostHold /\ hostHold' = FALSE /\ UNCHANGED <<st, reason, lease, res, measured, rejects>>

Done == \A j \in Jobs : st[j] \in {"completed","dropped"}

\* Full behaviour, including owner and host interventions: for safety.
Next ==
  \/ \E j \in Jobs : Record(j) \/ Admit(j) \/ LeaseLapse(j) \/ Checkpoint(j)
                     \/ Accept(j) \/ Reject(j) \/ Preempt(j) \/ Hold(j)
                     \/ Release(j) \/ Drop(j)
  \/ \E j \in Jobs, w \in Workers : Start(j, w)
  \/ HostHoldOn \/ HostHoldOff
  \/ (Done /\ UNCHANGED vars)

\* Machine-only behaviour, no owner holds or drops: for starvation.
AutoNext ==
  \/ \E j \in Jobs : Record(j) \/ Admit(j) \/ Checkpoint(j) \/ Accept(j)
                     \/ Reject(j) \/ Preempt(j)
  \/ \E j \in Jobs, w \in Workers : Start(j, w)
  \/ (Done /\ UNCHANGED vars)

Spec     == Init /\ [][Next]_vars
AutoSpec == Init /\ [][AutoNext]_vars
            /\ \A j \in Jobs : WF_vars(Record(j)) /\ WF_vars(Admit(j))
                               /\ WF_vars(Checkpoint(j)) /\ WF_vars(Accept(j))
                               /\ WF_vars(Reject(j)) /\ WF_vars(Preempt(j))
                               /\ WF_vars(\E w \in Workers : Start(j, w))

\* ---------------- Invariants: contract section 3 rules ----------------
TypeOK == /\ st \in [Jobs -> States] /\ reason \in [Jobs -> Reasons]
          /\ rejects \in [Jobs -> 0..MaxRejects] /\ measured \in [Jobs -> BOOLEAN]
          /\ lease \in [Jobs -> Workers \cup {None}] /\ res \in [Jobs -> 0..Cap]

R1_OneLeasePerJobAndWorker ==
  /\ \A j \in Jobs : (lease[j] # None) <=> (st[j] = "running")
  /\ \A j, k \in Jobs : j # k /\ lease[j] # None => lease[j] # lease[k]
R1_HeavySlots   == Cardinality(HeavyRunning) <= Slots
R2_WaitingSaid  == \A j \in Jobs : st[j] \notin {"running","completed","dropped"} => reason[j] # "none"
R4_Reservation  == /\ Reserved <= Cap
                   /\ \A j \in Jobs : (res[j] > 0) <=> (st[j] \in Active)
R6_ProbeCapped  == \A j \in Jobs : st[j] \in Active /\ ~measured[j] => res[j] = ProbeCap
Ownership       == \A j, k \in Jobs : j # k /\ Obl[j] = Obl[k] => ~(st[j] \in Active /\ st[k] \in Active)

\* ---------------- Liveness: no machine-made starvation ----------------
Terminates   == \A j \in Jobs : <>(st[j] \in {"completed","dropped","held"})
NoStarvation == \A j \in Jobs : (st[j] = "ready") ~> (st[j] \in {"running","held","completed","dropped"})
==========================================================================
