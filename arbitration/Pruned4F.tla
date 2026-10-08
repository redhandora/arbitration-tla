---------------------------- MODULE Pruned4F ----------------------------
(***************************************************************************)
(* A pruned sub-behaviour of Arbitration's Spec, to reach 4F1A states with *)
(* three proposal numbers, which the full Spec cannot exhaust.  Every      *)
(* PrunedNext step is one or two steps of Next, so any violation found     *)
(* here is reachable in Spec.  Pruned: A's push and proposal catch-up, and *)
(* upgrades; a crash is always followed at once by a restart.  Finding 4   *)
(* needs none of them.                                                     *)
(***************************************************************************)
EXTENDS Arbitration

\* Crash immediately followed by Restart.
Bounce(f) ==
  /\ alive[f]
  /\ role'          = [role EXCEPT ![f] = "Follower"]
  /\ promisedBy'    = [promisedBy EXCEPT ![f] = {}]
  /\ prepareConfig' = [prepareConfig EXCEPT ![f] = NoPrepareConfig]
  /\ pendingChange' = [pendingChange EXCEPT ![f] = None]
  /\ commitIndex'   = [commitIndex EXCEPT ![f] = 0]
  /\ matchIndex'    = [matchIndex EXCEPT ![f] = NoAcks]
  /\ UNCHANGED <<proposal, log, config, alive, committed>>

PrunedNext ==
  \/ \E c \in F, p \in 1..MaxProposal : Prepare(c, p)
  \/ \E c \in F, v \in Server         : Promise(v, c)
  \/ \E c \in F                       : RecoverLog(c)
  \/ \E l \in F                       : StartWorking(l)
  \/ \E l \in F                       : ConfirmConfig(l)
  \/ \E l, s \in F                    : Degrade(l, s)
  \/ \E l \in F, v \in Server         : AcceptConfig(v, l)
  \/ \E l \in F                       : CommitConfig(l)
  \/ \E l \in F                       : ClientWrite(l)
  \/ \E f, l \in F                    : AcceptEntry(f, l)
  \/ \E l \in F, i \in 1..MaxLogLen   : CommitEntries(l, i)
  \/ \E f \in F                       : Bounce(f)

PrunedSpec == Init /\ [][PrunedNext]_vars

=============================================================================
