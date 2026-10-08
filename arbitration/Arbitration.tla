---------------------------- MODULE Arbitration ----------------------------
(***************************************************************************)
(* Dual-quorum Paxos: PALF with an arbitration replica A, one log stream. *)
(*                                                                         *)
(* Grounded in OceanBase src/logservice/palf (github.com/oceanbase/        *)
(* oceanbase, commit 0fa1778); code names appear in parentheses.  Terms    *)
(* follow the paper (Section 5):                                           *)
(*                                                                         *)
(*  - The log commit member group S of a configuration is the set of full  *)
(*    replicas that accept and commit log entries (log_sync_memberlist).   *)
(*    Its election member group is E = S \cup {A}                          *)
(*    (convert_to_complete_config).  Degraded full replicas are learners   *)
(*    and do not vote.                                                     *)
(*  - A prepare quorum is a majority of E: elections and the Prepare phase *)
(*    use it.  An accept quorum is a majority of S: log entries commit on  *)
(*    it.  A stores no log and never counts toward an accept quorum.       *)
(*  - Each leader is identified by a proposal number (proposal_id).  A new *)
(*    leader runs log reconfirmation: the Prepare phase, log recovery from *)
(*    the replica with the largest (acc, LSN), and the StartWorking log.   *)
(*    The election itself does not compare logs.                           *)
(*  - A configuration is metadata (LogConfigMeta), not a log entry.  It    *)
(*    has a version (proposal number, sequence number) and a barrier, and  *)
(*    commits once a majority of the new configuration's E persists it.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  F,             \* full replicas
  A,             \* the arbitration replica
  None,          \* model value: no configuration change in flight
  MaxProposal,   \* bound on proposal numbers
  MaxLogLen,     \* bound on the log length (LSN)
  MaxConfigSeq   \* bound on configuration sequence numbers, i.e. on the
                 \* number of configuration changes

ASSUME A \notin F

Server == F \cup {A}

VARIABLES
  \* persistent: survive a crash
  proposal,      \* [Server -> Nat]  largest proposal number promised; for
                 \*   a leader, its own proposal number
  log,           \* [F -> Seq(Nat)]  each entry is the proposal number of
                 \*   the leader that wrote it
  config,        \* [Server -> [prev, curr, barrier]]  configuration metadata
  \* volatile: lost on a crash
  alive,         \* [Server -> BOOLEAN]
  role,          \* [F -> {"Follower", "Candidate", "Reconfirming", "Leader"}]
  promisedBy,    \* [F -> SUBSET Server]  replicas that promised the
                 \*   candidate's proposal number, incl. itself
                 \*   (prepare_log_ack_list_)
  prepareConfig, \* [F -> [members, version]]  the E and configuration
                 \*   version the candidate runs the Prepare phase with,
                 \*   fixed when it starts (curr_paxos_follower_list_)
  pendingChange, \* [F -> None or [kind, acks]]  configuration change in flight
  commitIndex,   \* [F -> Nat]  commit point (committed_end_lsn)
  matchIndex,    \* [F -> [F -> Nat]]  for leader l, the end of l's log that
                 \*   each replica has acknowledged to l (match_lsn_map_)
  \* history, only read by the invariants
  committed      \* SUBSET [index, proposal]  committed entries

vars == <<proposal, log, config, alive, role, promisedBy, prepareConfig,
          pendingChange, commitIndex, matchIndex, committed>>

-----------------------------------------------------------------------------
(* Helpers *)

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b
SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x

IsMajority(S, T) == Cardinality(S \cap T) * 2 > Cardinality(T)

\* The election member group E of s's current configuration.
ElectionGroup(s) == config[s].curr.commitGroup \cup {A}

LastEntryProposal(lg) == IF lg = << >> THEN 0 ELSE lg[Len(lg)]

\* acc: the proposal number a replica reports in the Prepare phase, the
\* larger of its last entry's and its configuration's (submit_prepare_log_).
\* The configuration part ranks a replica that accepted a configuration
\* above replicas that hold older, conflicting entries.
Acc(f) == Max(LastEntryProposal(log[f]), config[f].curr.version[1])

\* Configuration versions (proposal number, sequence number) compare
\* lexicographically (LogConfigVersion).
VersionLT(v1, v2) == \/ v1[1] < v2[1]
                     \/ v1[1] = v2[1] /\ v1[2] < v2[2]
VersionLE(v1, v2) == VersionLT(v1, v2) \/ v1 = v2

IsPrefix(a, b) == Len(a) <= Len(b) /\ SubSeq(b, 1, Len(a)) = a

\* f's log matches that of configuration m's leader up to m's barrier, so f
\* may accept m (pre_check_for_config_log).
\* (IF, not \/: inside an action TLC evaluates every disjunct.)
MatchesBarrier(f, m) ==
  IF m.barrier.index = 0
  THEN TRUE
  ELSE /\ Len(log[f]) >= m.barrier.index
       /\ log[f][m.barrier.index] = m.barrier.proposal

\* On accepting configuration m, f discards stale entries: if the entry
\* after the barrier has a proposal number below the configuration's own,
\* everything after the barrier is truncated (pre_check_for_config_log).
\* This keeps acc faithful to the log.
\*
\* FIX (see findings.md, finding 2): the code compares with the message's
\* proposal number.  That equals the configuration's own when a leader
\* sends its configuration, but not when A forwards an older configuration
\* with its current, larger proposal number
\* (sync_meta_for_arb_election_leader); then committed entries that the
\* configuration's leader wrote after the barrier were truncated.  The
\* model compares with the configuration's own proposal number
\* (config.proposal_id_ = curr.version[1]), which leaves the leader's own
\* path unchanged.
TruncateStaleEntries(f, m) ==
  IF Len(log[f]) > m.barrier.index /\ log[f][m.barrier.index + 1] < m.curr.version[1]
  THEN SubSeq(log[f], 1, m.barrier.index)
  ELSE log[f]

\* Q is a prepare quorum that can elect c: c is in Q, Q is a majority of
\* c's E, and no voter holds a newer configuration version
\* (ElectionAcceptor::on_prepare_request ignores a lower
\* membership_version).
IsPrepareQuorum(Q, c) ==
  /\ c \in Q
  /\ Q \subseteq ElectionGroup(c)
  /\ IsMajority(Q, ElectionGroup(c))
  /\ \A v \in Q : VersionLE(config[v].curr.version, config[c].curr.version)

CanBeElected(c) ==
  \E Q \in SUBSET ElectionGroup(c) :
     IsPrepareQuorum(Q, c) /\ \A v \in Q : alive[v]

\* The full replicas in Q with the largest (acc, LSN): log recovery fetches
\* from one of them.  A is never a source.
RecoverySources(Q) ==
  { m \in Q \cap F :
      \A f \in Q \cap F :
         \/ Acc(f) < Acc(m)
         \/ Acc(f) = Acc(m) /\ Len(log[f]) <= Len(log[m]) }

\* The configuration leader l proposes with log commit member group S:
\* version (l's proposal number, sequence number + 1) and a barrier at the
\* end of l's log (append_config_meta_, renew_config_change_barrier_).
NextConfig(l, S) ==
  [prev    |-> config[l].curr,
   curr    |-> [version     |-> <<proposal[l], config[l].curr.version[2] + 1>>,
                commitGroup |-> S],
   barrier |-> [index |-> Len(log[l]), proposal |-> LastEntryProposal(log[l])]]

\* No acknowledgments yet (see matchIndex).
NoAcks == [f \in F |-> 0]

\* Leader l knows that f holds l's log up to position i: f acknowledged it
\* (match_lsn_map_).  l counts itself.  l decides only on acknowledgments,
\* never on the replicas' current logs: a replica may hold the same
\* entries without having accepted them from l, e.g. through its own log
\* recovery under a larger proposal number.
Acked(l, f, i) == f = l \/ matchIndex[l][f] >= i

\* Pre-change synchronization: a majority of S has acknowledged the
\* leader's whole log, up to what becomes the barrier (wait_log_barrier_,
\* check_follower_sync_status_, is_accept_quorum_catch_up_).
MajorityHoldsLeaderLog(l, S) == IsMajority({f \in S : Acked(l, f, Len(log[l]))}, S)

Entries(lg, n) == { [index |-> j, proposal |-> lg[j]] : j \in 1..n }

HoldsEntry(lg, e) == Len(lg) >= e.index /\ lg[e.index] = e.proposal

\* No Prepare phase in progress (see prepareConfig).
NoPrepareConfig == [members |-> {}, version |-> <<0, 0>>]

\* A replica that learns a larger proposal number steps down from any
\* leader role (LogStateMgr::handle_prepare_request).
StepsDown(v, p) == v \in F /\ role[v] # "Follower" /\ proposal[v] < p

\* The volatile state of v after it learns proposal number p.
IfStepsDown(v, p, var, reset) ==
  [x \in F |-> IF x = v /\ StepsDown(v, p) THEN reset ELSE var[x]]

RoleAfter(v, p)          == IfStepsDown(v, p, role, "Follower")
PromisedByAfter(v, p)    == IfStepsDown(v, p, promisedBy, {})
PrepareConfigAfter(v, p) == IfStepsDown(v, p, prepareConfig, NoPrepareConfig)
PendingChangeAfter(v, p) == IfStepsDown(v, p, pendingChange, None)
MatchIndexAfter(v, p)    == IfStepsDown(v, p, matchIndex, NoAcks)

\* v may accept configuration m sent with proposal number p
\* (try_update_proposal_id_, can_receive_config_log).  A has no log and
\* skips the barrier check.
ConfigAcceptable(v, m, p) ==
  /\ alive[v]
  /\ proposal[v] <= p
  /\ VersionLE(config[v].curr.version, m.curr.version)
  /\ v \in F => MatchesBarrier(v, m)

-----------------------------------------------------------------------------
(* Initial state *)

InitialConfig     == [version |-> <<0, 0>>, commitGroup |-> F]
InitialConfigMeta == [prev    |-> InitialConfig,
                      curr    |-> InitialConfig,
                      barrier |-> [index |-> 0, proposal |-> 0]]

Init ==
  /\ proposal      = [s \in Server |-> 0]
  /\ log           = [f \in F |-> << >>]
  /\ config        = [s \in Server |-> InitialConfigMeta]
  /\ alive         = [s \in Server |-> TRUE]
  /\ role          = [f \in F |-> "Follower"]
  /\ promisedBy    = [f \in F |-> {}]
  /\ prepareConfig = [f \in F |-> NoPrepareConfig]
  /\ pendingChange = [f \in F |-> None]
  /\ commitIndex   = [f \in F |-> 0]
  /\ matchIndex    = [l \in F |-> NoAcks]
  /\ committed     = {}

-----------------------------------------------------------------------------
(* Log reconfirmation (log_reconfirm.cpp): election, Prepare phase and log *)
(* recovery.                                                               *)

\* c has won the election (palf/election, which does not compare logs) and
\* starts the Prepare phase with a larger proposal number p
\* (LogReconfirm::submit_prepare_log_).  The election lease is not
\* modelled, so several election leaders may coexist; safety rests on
\* proposal numbers alone.
Prepare(c, p) ==
  /\ alive[c]
  /\ role[c] \in {"Follower", "Candidate"}
  /\ c \in config[c].curr.commitGroup   \* learners do not campaign (ElectionProposer)
  /\ CanBeElected(c)
  /\ proposal[c] < p
  /\ proposal'      = [proposal EXCEPT ![c] = p]
  /\ role'          = [role EXCEPT ![c] = "Candidate"]
  /\ promisedBy'    = [promisedBy EXCEPT ![c] = {c}]
  /\ prepareConfig' = [prepareConfig EXCEPT ![c] =           \* init_reconfirm_
                         [members |-> ElectionGroup(c),
                          version |-> config[c].curr.version]]
  /\ pendingChange' = [pendingChange EXCEPT ![c] = None]
  /\ UNCHANGED <<log, config, alive, commitIndex, matchIndex, committed>>

\* v promises c's proposal number (LogStateMgr::handle_prepare_request).
\* c runs the Prepare phase only while it holds the election, and v backs c
\* only if c's configuration version is not lower than its own
\* (ElectionAcceptor ignores a lower membership_version), so v filters by
\* configuration version here.  The version is the one c campaigned with,
\* fixed when the Prepare phase starts, like E: a configuration that c
\* accepts later from another leader with the same proposal number does
\* not make its campaign newer.
Promise(v, c) ==
  /\ role[c] = "Candidate"
  /\ alive[c]
  /\ alive[v]
  /\ v \in prepareConfig[c].members \ {c}
  /\ VersionLE(config[v].curr.version, prepareConfig[c].version)
  /\ proposal[v] < proposal[c]
  /\ proposal'      = [proposal EXCEPT ![v] = proposal[c]]
  /\ role'          = RoleAfter(v, proposal[c])
  /\ promisedBy'    = [x \in F |-> IF x = c THEN promisedBy[c] \cup {v}
                                   ELSE IF x = v /\ StepsDown(v, proposal[c]) THEN {}
                                   ELSE promisedBy[x]]
  /\ prepareConfig' = PrepareConfigAfter(v, proposal[c])
  /\ pendingChange' = PendingChangeAfter(v, proposal[c])
  /\ matchIndex'    = MatchIndexAfter(v, proposal[c])
  /\ UNCHANGED <<log, config, alive, commitIndex, committed>>

\* Once a prepare quorum of the E fixed at the start has promised
\* (prepare_quorum_cnt_ is computed once in init_reconfirm_), c fetches the
\* log of a full replica with the largest (acc, LSN) among them
\* (FETCH_MAX_LOG_LSN, RECONFIRM_FETCH_LOG).  c is now the leader of its
\* proposal number, still in log reconfirmation.
RecoverLog(c) ==
  /\ role[c] = "Candidate"
  /\ alive[c]
  /\ IsMajority(promisedBy[c], prepareConfig[c].members)
  /\ \E m \in RecoverySources(promisedBy[c]) :
        /\ alive[m]
        /\ log' = [log EXCEPT ![c] = log[m]]
  /\ role'          = [role EXCEPT ![c] = "Reconfirming"]
  /\ prepareConfig' = [prepareConfig EXCEPT ![c] = NoPrepareConfig]
  /\ matchIndex'    = [matchIndex EXCEPT ![c] = NoAcks]
  /\ UNCHANGED <<proposal, config, alive, promisedBy, pendingChange, commitIndex,
                 committed>>

-----------------------------------------------------------------------------
(* Configuration changes (log_config_mgr.cpp).  A configuration commits    *)
(* once a majority of the NEW configuration's E has persisted it.          *)

\* The leader first writes the configuration to its own metadata, then
\* sends it (append_config_meta_).
ProposeConfig(l, S, kind) ==
  /\ config'        = [config EXCEPT ![l] = NextConfig(l, S)]
  /\ pendingChange' = [pendingChange EXCEPT ![l] = [kind |-> kind, acks |-> {l}]]
  /\ UNCHANGED <<proposal, log, alive, role, promisedBy, prepareConfig, commitIndex,
                 matchIndex, committed>>

CanPropose(l) ==
  /\ alive[l]
  /\ pendingChange[l] = None
  /\ config[l].curr.version[2] < MaxConfigSeq

\* The StartWorking log (confirm_start_working_log): once an accept quorum
\* of S holds the recovered log (is_accept_quorum_catch_up_), the new
\* leader re-proposes its configuration under its own proposal number.  Its
\* commit ends log reconfirmation and commits the recovered log up to the
\* barrier.
StartWorking(l) ==
  /\ role[l] = "Reconfirming"
  /\ CanPropose(l)
  /\ MajorityHoldsLeaderLog(l, config[l].curr.commitGroup)
  /\ ProposeConfig(l, config[l].curr.commitGroup, "StartWorking")

\* Degrade: turn member s of S into a learner
\* (degrade_acceptor_to_learner).  The arbitration service degrades half of
\* F, one member per change (one_stage_config_change_), so consecutive
\* configurations differ by one member and S never drops below half of F.
\* Pre-change synchronization: a majority of the new S already holds the
\* leader's log.  s may be alive: failure detection can be wrong.
CanDegrade(l, s) ==
  /\ s \in config[l].curr.commitGroup \ {l}
  /\ Cardinality(config[l].curr.commitGroup \ {s}) * 2 >= Cardinality(F)
  /\ MajorityHoldsLeaderLog(l, config[l].curr.commitGroup \ {s})

\* FIX (see findings.md, finding 4): configuration confirmation.  Before
\* degrading during log reconfirmation, a new leader re-proposes the
\* configuration it inherited under its own proposal number and waits for
\* it to commit on a majority of E, but not for the log as StartWorking
\* does.  The inherited configuration may be an unfinished change of an
\* earlier leader; once a majority of E holds it under the new proposal
\* number, no older configuration, and no change another leader proposed
\* under a smaller proposal number, can gather a prepare quorum (Lemma 2).
\* The code degrades right after log recovery (can_do_degrade); in 4F1A
\* two degrades by two leaders then leave two configurations that can
\* both elect but whose prepare quorums are disjoint.
\*
\* The leader confirms only when it is about to degrade a member.  A may
\* then hold the confirmation before that member has the leader's log; if
\* the leader fails before the degrade commits, the remaining replicas
\* wait for it, as they would right after the degrade (the single-copy
\* window, see NoLearnerWindow).
ConfirmConfig(l) ==
  /\ role[l] = "Reconfirming"
  /\ CanPropose(l)
  /\ config[l].curr.version[1] < proposal[l]
  /\ \E s \in F : CanDegrade(l, s)
  /\ ProposeConfig(l, config[l].curr.commitGroup, "Confirm")

\* l's configuration has the proposal number of l itself: l proposed it.
\* Together with CanPropose (nothing in flight) it has committed, through
\* configuration confirmation, the StartWorking log, or an earlier change
\* of l.  A crash or a larger proposal number ends l's role.
ConfigConfirmed(l) == config[l].curr.version[1] = proposal[l]

\* Degrade s.  Allowed during log reconfirmation once the log is recovered
\* (can_do_degrade), and, with the fix, once the configuration is
\* confirmed.
Degrade(l, s) ==
  /\ role[l] \in {"Reconfirming", "Leader"}
  /\ CanPropose(l)
  /\ ConfigConfirmed(l)
  /\ CanDegrade(l, s)
  /\ ProposeConfig(l, config[l].curr.commitGroup \ {s}, "Degrade")

\* Upgrade: turn a learner m that has acknowledged the leader's whole log
\* back into a member of S (upgrade_learner_to_acceptor).
Upgrade(l, m) ==
  /\ role[l] = "Leader"
  /\ CanPropose(l)
  /\ m \in F \ config[l].curr.commitGroup
  /\ alive[m]
  /\ Acked(l, m, Len(log[l]))
  /\ MajorityHoldsLeaderLog(l, config[l].curr.commitGroup \cup {m})
  /\ ProposeConfig(l, config[l].curr.commitGroup \cup {m}, "Upgrade")

\* v accepts leader l's configuration (submit_config_log_ /
\* receive_config_log): either the change in flight, or a resend of the
\* current configuration to a replica that is behind.  Learners receive it
\* too, but only acknowledgments from the new E count.
AcceptConfig(v, l) ==
  /\ l \in F
  /\ alive[l]
  /\ v # l
  /\ \/ pendingChange[l] # None /\ v \notin pendingChange[l].acks
     \/ /\ role[l] = "Leader"
        /\ pendingChange[l] = None
        /\ VersionLT(config[v].curr.version, config[l].curr.version)
  /\ ConfigAcceptable(v, config[l], proposal[l])
  /\ proposal'      = [proposal EXCEPT ![v] = proposal[l]]
  /\ config'        = [config EXCEPT ![v] = config[l]]
  /\ log'           = IF v \in F
                        THEN [log EXCEPT ![v] = TruncateStaleEntries(v, config[l])]
                        ELSE log
  /\ role'          = RoleAfter(v, proposal[l])
  /\ promisedBy'    = PromisedByAfter(v, proposal[l])
  /\ prepareConfig' = PrepareConfigAfter(v, proposal[l])
  /\ pendingChange' = [x \in F |-> IF x = l /\ pendingChange[l] # None
                                     THEN [pendingChange[l] EXCEPT !.acks = @ \cup {v}]
                                   ELSE IF x = v /\ StepsDown(v, proposal[l]) THEN None
                                   ELSE pendingChange[x]]
  /\ matchIndex'    = MatchIndexAfter(v, proposal[l])
  /\ UNCHANGED <<alive, commitIndex, committed>>

\* The change commits once a majority of the new E has persisted it
\* (is_reach_majority_).  Committing the StartWorking log ends log
\* reconfirmation and commits the recovered log up to the barrier
\* (saved_end_lsn_).
CommitConfig(l) ==
  /\ alive[l]
  /\ pendingChange[l] # None
  /\ IsMajority(pendingChange[l].acks, ElectionGroup(l))
  /\ pendingChange' = [pendingChange EXCEPT ![l] = None]
  /\ IF pendingChange[l].kind = "StartWorking"
       THEN /\ role'        = [role EXCEPT ![l] = "Leader"]
            /\ commitIndex' = [commitIndex EXCEPT ![l] = config[l].barrier.index]
            /\ committed'   = committed \cup Entries(log[l], config[l].barrier.index)
       ELSE UNCHANGED <<role, commitIndex, committed>>
  /\ UNCHANGED <<proposal, log, config, alive, promisedBy, prepareConfig, matchIndex>>

\* When A is the election leader it pushes its configuration to the full
\* replicas (sync_meta_for_arb_election_leader); A never runs log
\* reconfirmation.  The message carries A's current proposal number with
\* the barrier of A's configuration (pre_sync_config_log_and_mode_meta_).
\* No lease is assumed: a full replica may still hold a leader role; like
\* any receiver it steps down if A's proposal number is larger
\* (can_receive_config_log also accepts a leader in log reconfirmation at
\* an equal proposal number).
ArbiterPushConfig(f) ==
  /\ alive[A]
  /\ CanBeElected(A)
  /\ VersionLT(config[f].curr.version, config[A].curr.version)
  /\ ConfigAcceptable(f, config[A], proposal[A])
  /\ proposal'      = [proposal EXCEPT ![f] = proposal[A]]
  /\ config'        = [config EXCEPT ![f] = config[A]]
  /\ log'           = [log EXCEPT ![f] = TruncateStaleEntries(f, config[A])]
  /\ role'          = RoleAfter(f, proposal[A])
  /\ promisedBy'    = PromisedByAfter(f, proposal[A])
  /\ prepareConfig' = PrepareConfigAfter(f, proposal[A])
  /\ pendingChange' = PendingChangeAfter(f, proposal[A])
  /\ matchIndex'    = MatchIndexAfter(f, proposal[A])
  /\ UNCHANGED <<alive, commitIndex, committed>>

\* FIX (see findings.md, finding 3): a receiver that rejects A's push
\* because it promised a larger proposal number replies with that number,
\* and A catches up, as a Raft node catches up on a larger term; A's next
\* push is then accepted.  In the code the receiver rejects silently
\* (can_receive_config_log requires equal proposal numbers), so A could
\* never push to replicas that had promised a larger proposal number to a
\* candidate that then failed.  Raising A's own proposal number only makes
\* A reject more.
ArbiterAdoptProposal(f) ==
  /\ alive[A]
  /\ alive[f]
  /\ CanBeElected(A)
  /\ VersionLT(config[f].curr.version, config[A].curr.version)
  /\ proposal[A] < proposal[f]
  /\ proposal' = [proposal EXCEPT ![A] = proposal[f]]
  /\ UNCHANGED <<log, config, alive, role, promisedBy, prepareConfig, pendingChange,
                 commitIndex, matchIndex, committed>>

-----------------------------------------------------------------------------
(* Log replication and commit (log_sliding_window.cpp) *)

\* Writes are allowed while a configuration change is in flight; only the
\* commit point is frozen (gen_committed_end_lsn_).
ClientWrite(l) ==
  /\ alive[l]
  /\ role[l] = "Leader"
  /\ Len(log[l]) < MaxLogLen
  /\ log' = [log EXCEPT ![l] = Append(@, proposal[l])]
  /\ UNCHANGED <<proposal, config, alive, role, promisedBy, prepareConfig, pendingChange,
                 commitIndex, matchIndex, committed>>

FirstDiff(a, b) ==
  CHOOSE i \in 1..Min(Len(a), Len(b)) :
     /\ a[i] # b[i]
     /\ \A j \in 1..(i - 1) : a[j] = b[j]

\* f accepts one step of leader l's log: append the next entry when f's
\* log is a prefix of l's, or drop f's suffix from the first conflict, or,
\* when f already holds l's log, accept nothing new.  f then acknowledges
\* the prefix it shares with l (match_lsn_map_), and adopts l's proposal
\* number (try_update_proposal_id_, can_receive_log).  Learners accept
\* entries too.
AcceptEntry(f, l) ==
  /\ f # l
  /\ alive[f]
  /\ alive[l]
  /\ role[l] \in {"Reconfirming", "Leader"}
  /\ proposal[f] <= proposal[l]
  /\ \/ /\ IsPrefix(log[f], log[l])
        /\ Len(log[f]) < Len(log[l])
        /\ log' = [log EXCEPT ![f] = Append(log[f], log[l][Len(log[f]) + 1])]
     \/ /\ \E i \in 1..Min(Len(log[f]), Len(log[l])) : log[f][i] # log[l][i]
        /\ log' = [log EXCEPT ![f] = SubSeq(log[f], 1, FirstDiff(log[f], log[l]) - 1)]
     \/ /\ IsPrefix(log[l], log[f])
        /\ matchIndex[l][f] < Len(log[l])
        /\ UNCHANGED log
  /\ proposal'      = [proposal EXCEPT ![f] = proposal[l]]
  /\ role'          = RoleAfter(f, proposal[l])
  /\ promisedBy'    = PromisedByAfter(f, proposal[l])
  /\ prepareConfig' = PrepareConfigAfter(f, proposal[l])
  /\ pendingChange' = PendingChangeAfter(f, proposal[l])
  /\ matchIndex'    = [x \in F |->
                         IF x = l
                         THEN [matchIndex[l] EXCEPT ![f] =
                                 Max(@, Min(Len(log'[f]), Len(log[l])))]
                         ELSE IF x = f /\ StepsDown(f, proposal[l]) THEN NoAcks
                         ELSE matchIndex[x]]
  /\ UNCHANGED <<config, alive, commitIndex, committed>>

\* Position i of l's log is accepted by a majority of T: an accept quorum
\* has acknowledged it (match_lsn_map_).
AcceptedBy(l, i, T) == IsMajority({f \in T : Acked(l, f, i)}, T)

\* gen_committed_end_lsn_: before the barrier, an accept quorum of either
\* the previous or the current S may commit, capped at the barrier; after
\* it, only the current S.  A never counts.
CanCommitUpTo(l, i) ==
  LET b == config[l].barrier.index IN
  IF commitIndex[l] < b
  THEN /\ i <= b
       /\ \/ AcceptedBy(l, i, config[l].prev.commitGroup)
          \/ AcceptedBy(l, i, config[l].curr.commitGroup)
  ELSE AcceptedBy(l, i, config[l].curr.commitGroup)

\* Commit freeze: no commit while a configuration change involving A is in
\* flight (is_changing_config_with_arb).
CommitEntries(l, i) ==
  /\ alive[l]
  /\ role[l] = "Leader"
  /\ pendingChange[l] = None
  /\ commitIndex[l] < i
  /\ i <= Len(log[l])
  /\ CanCommitUpTo(l, i)
  /\ commitIndex' = [commitIndex EXCEPT ![l] = i]
  /\ committed'   = committed \cup Entries(log[l], i)
  /\ UNCHANGED <<proposal, log, config, alive, role, promisedBy, prepareConfig,
                 pendingChange, matchIndex>>

-----------------------------------------------------------------------------
(* Failures.  A crash keeps the proposal number, the log and the           *)
(* configuration, and drops everything else.  A partition needs no action: *)
(* steps between the two sides simply do not happen, and a partitioned     *)
(* leader keeps acting on its own.                                         *)

Crash(s) ==
  /\ alive[s]
  /\ alive' = [alive EXCEPT ![s] = FALSE]
  /\ IF s \in F
       THEN /\ role'          = [role EXCEPT ![s] = "Follower"]
            /\ promisedBy'    = [promisedBy EXCEPT ![s] = {}]
            /\ prepareConfig' = [prepareConfig EXCEPT ![s] = NoPrepareConfig]
            /\ pendingChange' = [pendingChange EXCEPT ![s] = None]
            /\ commitIndex'   = [commitIndex EXCEPT ![s] = 0]
            /\ matchIndex'    = [matchIndex EXCEPT ![s] = NoAcks]
       ELSE UNCHANGED <<role, promisedBy, prepareConfig, pendingChange, commitIndex,
                        matchIndex>>
  /\ UNCHANGED <<proposal, log, config, committed>>

Restart(s) ==
  /\ ~alive[s]
  /\ alive' = [alive EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<proposal, log, config, role, promisedBy, prepareConfig, pendingChange,
                 commitIndex, matchIndex, committed>>

-----------------------------------------------------------------------------
(* Next-state relation *)

Next ==
  \/ \E c \in F, p \in 1..MaxProposal : Prepare(c, p)
  \/ \E c \in F, v \in Server         : Promise(v, c)
  \/ \E c \in F                       : RecoverLog(c)
  \/ \E l \in F                       : StartWorking(l)
  \/ \E l \in F                       : ConfirmConfig(l)
  \/ \E l, s \in F                    : Degrade(l, s)
  \/ \E l, m \in F                    : Upgrade(l, m)
  \/ \E l \in F, v \in Server         : AcceptConfig(v, l)
  \/ \E l \in F                       : CommitConfig(l)
  \/ \E f \in F                       : ArbiterPushConfig(f)
  \/ \E f \in F                       : ArbiterAdoptProposal(f)
  \/ \E l \in F                       : ClientWrite(l)
  \/ \E f, l \in F                    : AcceptEntry(f, l)
  \/ \E l \in F, i \in 1..MaxLogLen   : CommitEntries(l, i)
  \/ \E s \in Server                  : Crash(s) \/ Restart(s)

Spec == Init /\ [][Next]_vars

Symmetry == Permutations(F)

-----------------------------------------------------------------------------
(* Safety: Theorem 1, Lemma 2 and supporting invariants *)

VersionType    == (0..MaxProposal) \X (0..MaxConfigSeq)
ConfigType     == [version : VersionType, commitGroup : SUBSET F]
ConfigMetaType == [prev : ConfigType, curr : ConfigType,
                   barrier : [index : 0..MaxLogLen, proposal : 0..MaxProposal]]

TypeOK ==
  /\ proposal      \in [Server -> 0..MaxProposal]
  /\ log           \in [F -> Seq(1..MaxProposal)]
  /\ \A f \in F : Len(log[f]) <= MaxLogLen
  /\ config        \in [Server -> ConfigMetaType]
  /\ alive         \in [Server -> BOOLEAN]
  /\ role          \in [F -> {"Follower", "Candidate", "Reconfirming", "Leader"}]
  /\ promisedBy    \in [F -> SUBSET Server]
  /\ prepareConfig \in [F -> [members : SUBSET Server, version : VersionType]]
  /\ pendingChange \in [F -> {None} \cup
                         [kind : {"StartWorking", "Confirm", "Degrade", "Upgrade"},
                          acks : SUBSET Server]]
  /\ commitIndex   \in [F -> 0..MaxLogLen]
  /\ matchIndex    \in [F -> [F -> 0..MaxLogLen]]
  /\ committed     \subseteq [index : 1..MaxLogLen, proposal : 1..MaxProposal]

\* Theorem 1(a), leader completeness: a leader holds every committed entry
\* whose proposal number is not above its own.
LeaderCompleteness ==
  \A l \in F :
     role[l] = "Leader" =>
        \A e \in committed : e.proposal <= proposal[l] => HoldsEntry(log[l], e)

\* Theorem 1(a), checked ahead of time: every candidate that could finish
\* the Prepare phase now would recover every committed entry, from any
\* prepare quorum that can elect it.
RecoveryComplete ==
  \A c \in F :
     c \in config[c].curr.commitGroup =>
        \A Q \in SUBSET ElectionGroup(c) :
           IsPrepareQuorum(Q, c) =>
              \A m \in RecoverySources(Q) : \A e \in committed : HoldsEntry(log[m], e)

\* Theorem 1(b), agreement: no LSN is committed with two different
\* proposal numbers.
Agreement ==
  \A e1, e2 \in committed : e1.index = e2.index => e1.proposal = e2.proposal

\* Lemma 2: the configurations that can still elect a leader are adjacent,
\* i.e. their log commit member groups differ by at most one member, so
\* their prepare quorums intersect (Lemma 1(b)).  Pairwise adjacent groups
\* number at most two: the last configuration committed under its
\* proposer's own proposal number, and one change in progress on top of
\* it.  Configuration X can elect if a member of its S holds X and a
\* majority of its E holds no newer version.  This ignores liveness and
\* promised proposal numbers, so it over-approximates.
CanElect(X) ==
  /\ \E c \in X.commitGroup : config[c].curr = X
  /\ LET E == X.commitGroup \cup {A} IN
     IsMajority({v \in E : VersionLE(config[v].curr.version, X.version)}, E)

Adjacent(S1, S2) == Cardinality((S1 \ S2) \cup (S2 \ S1)) <= 1

ElectableConfigsAdjacent ==
  \A f1, f2 \in F :
     CanElect(config[f1].curr) /\ CanElect(config[f2].curr)
        => Adjacent(config[f1].curr.commitGroup, config[f2].curr.commitGroup)

\* Lemma 2, consequence: at most one replica completes the Prepare phase
\* per proposal number.
OneLeaderPerProposal ==
  \A l1, l2 \in F :
     /\ l1 # l2
     /\ role[l1] \in {"Reconfirming", "Leader"}
     /\ role[l2] \in {"Reconfirming", "Leader"}
     => proposal[l1] # proposal[l2]

\* Lemma 2, consequence: at most one leader can make progress, i.e. could
\* advance its commit point: nothing in flight, and no accept quorum of its
\* S has promised a larger proposal number.
ActiveLeader(l) ==
  /\ role[l] = "Leader"
  /\ pendingChange[l] = None
  /\ IsMajority({f \in config[l].curr.commitGroup : proposal[f] <= proposal[l]},
                config[l].curr.commitGroup)

OneActiveLeader ==
  \A l1, l2 \in F : ActiveLeader(l1) /\ ActiveLeader(l2) => l1 = l2

LogMatching ==
  \A f1, f2 \in F :
     \A i \in 1..Min(Len(log[f1]), Len(log[f2])) :
        log[f1][i] = log[f2][i] => SubSeq(log[f1], 1, i) = SubSeq(log[f2], 1, i)

\* A's configuration is never ahead of what a majority of its S can catch
\* up to: they already hold it or a newer one, or their log matches its
\* barrier, so they can accept it from A.  A configuration confirmation
\* (the same S under a larger proposal number) is the first step of a
\* degrade, and A may be ahead of the member about to be degraded; a
\* majority of the others suffices then.
CanCatchUp(f, m) ==
  VersionLE(m.curr.version, config[f].curr.version) \/ MatchesBarrier(f, m)

IsConfirmation(m) ==
  /\ m.curr.commitGroup = m.prev.commitGroup
  /\ m.prev.version[1] < m.curr.version[1]

ArbiterNotAhead ==
  LET m     == config[A]
      S     == m.curr.commitGroup
      Ready == {f \in S : CanCatchUp(f, m)}
  IN  \/ IsMajority(Ready, S)
      \/ IsConfirmation(m) /\ \E s \in S : IsMajority(Ready, S \ {s})

CommittedMonotonic == [][committed \subseteq committed']_vars

ProposalMonotonic == [][\A s \in Server : proposal'[s] >= proposal[s]]_vars

ConfigVersionMonotonic ==
  [][\A s \in Server : VersionLE(config[s].curr.version, config'[s].curr.version)]_vars

-----------------------------------------------------------------------------
(* Liveness (Theorem 2): from a clean start, a minority failure never      *)
(* stops service.                                                          *)
(*                                                                         *)
(* Environment assumptions, used only here (Spec makes none of them).      *)
(* They hold from Init on; recovery after a messy prefix (competing        *)
(* candidates, a wrong degrade, restarts) is not covered:                  *)
(*  - failures are permanent and always a minority of Server;              *)
(*  - the election is stable: nobody campaigns while another live full     *)
(*    replica is past Follower (A pushes as election leader only while     *)
(*    every live full replica is a Follower), and a candidate retries only *)
(*    when stuck, with a proposal number above every live replica's;       *)
(*  - failure detection is accurate: only failed full replicas are         *)
(*    degraded, and a leader confirms its configuration only when it has a *)
(*    failed member to degrade;                                            *)
(*  - weak fairness for every protocol step except client writes.          *)

Down == {s \in Server : ~alive[s]}

CrashLive(s) == Crash(s) /\ Cardinality(Down \cup {s}) * 2 < Cardinality(Server)

NextProposal == 1 + SetMax({proposal[s] : s \in Server \ Down})

OthersFollow(c) == \A f \in F \ {c} : ~alive[f] \/ role[f] = "Follower"

\* c cannot finish the Prepare phase: RecoverLog is impossible and no more
\* promises can come.
PrepareStuck(c) ==
  /\ role[c] = "Candidate"
  /\ ~(/\ IsMajority(promisedBy[c], prepareConfig[c].members)
       /\ \E m \in RecoverySources(promisedBy[c]) : alive[m])
  /\ {v \in prepareConfig[c].members \ promisedBy[c] :
        /\ alive[v]
        /\ proposal[v] < proposal[c]
        /\ VersionLE(config[v].curr.version, prepareConfig[c].version)} = {}

PrepareLive(c) ==
  /\ OthersFollow(c)
  /\ role[c] = "Follower" \/ PrepareStuck(c)
  /\ NextProposal <= MaxProposal
  /\ Prepare(c, NextProposal)

ConfirmLive(l) ==
  /\ \E s \in config[l].curr.commitGroup : ~alive[s] /\ CanDegrade(l, s)
  /\ ConfirmConfig(l)

DegradeLive(l) == \E s \in config[l].curr.commitGroup : ~alive[s] /\ Degrade(l, s)

\* A acts as the election leader (and pushes its configuration) only while
\* no live full replica holds the election: the same election-stability
\* assumption as for full replicas.
ArbiterIsElectionLeader == \A f \in F : ~alive[f] \/ role[f] = "Follower"
ArbiterPushLive(f)      == ArbiterIsElectionLeader /\ ArbiterPushConfig(f)
ArbiterAdoptLive(f)     == ArbiterIsElectionLeader /\ ArbiterAdoptProposal(f)

\* A stuck candidate that can no longer win the election loses it (its
\* election lease is not renewed), so that another full replica may
\* campaign.
LoseElection(c) ==
  /\ PrepareStuck(c)
  /\ ~CanBeElected(c)
  /\ role'          = [role EXCEPT ![c] = "Follower"]
  /\ promisedBy'    = [promisedBy EXCEPT ![c] = {}]
  /\ prepareConfig' = [prepareConfig EXCEPT ![c] = NoPrepareConfig]
  /\ UNCHANGED <<proposal, log, config, alive, pendingChange, commitIndex, matchIndex,
                 committed>>

LiveNext ==
  \/ \E c \in F                     : PrepareLive(c)
  \/ \E c \in F                     : LoseElection(c)
  \/ \E c \in F, v \in Server       : Promise(v, c)
  \/ \E c \in F                     : RecoverLog(c)
  \/ \E l \in F                     : StartWorking(l)
  \/ \E l \in F                     : ConfirmLive(l)
  \/ \E l \in F                     : DegradeLive(l)
  \/ \E l \in F, v \in Server       : AcceptConfig(v, l)
  \/ \E l \in F                     : CommitConfig(l)
  \/ \E f \in F                     : ArbiterPushLive(f)
  \/ \E f \in F                     : ArbiterAdoptLive(f)
  \/ \E l \in F                     : ClientWrite(l)
  \/ \E f, l \in F                  : AcceptEntry(f, l)
  \/ \E l \in F, i \in 1..MaxLogLen : CommitEntries(l, i)
  \/ \E s \in Server                : CrashLive(s)

Fairness ==
  /\ \A c \in F                     : WF_vars(PrepareLive(c))
  /\ \A c \in F                     : WF_vars(LoseElection(c))
  /\ \A c \in F, v \in Server       : WF_vars(Promise(v, c))
  /\ \A c \in F                     : WF_vars(RecoverLog(c))
  /\ \A l \in F                     : WF_vars(StartWorking(l))
  /\ \A l \in F                     : WF_vars(ConfirmLive(l))
  /\ \A l \in F                     : WF_vars(DegradeLive(l))
  /\ \A l \in F, v \in Server       : WF_vars(AcceptConfig(v, l))
  /\ \A l \in F                     : WF_vars(CommitConfig(l))
  /\ \A f \in F                     : WF_vars(ArbiterPushLive(f))
  /\ \A f \in F                     : WF_vars(ArbiterAdoptLive(f))
  /\ \A f, l \in F                  : WF_vars(AcceptEntry(f, l))
  /\ \A l \in F, i \in 1..MaxLogLen : WF_vars(CommitEntries(l, i))

LiveSpec == Init /\ [][LiveNext]_vars /\ Fairness

\* A live leader, with nothing in flight, whose S has a live majority: it
\* can commit writes.
StableLeader(l) ==
  /\ alive[l]
  /\ role[l] = "Leader"
  /\ pendingChange[l] = None
  /\ LET S == config[l].curr.commitGroup IN IsMajority({f \in S : alive[f]}, S)

\* Service resumes: eventually there is a stable leader forever.
EventuallyStableLeader == <>[](\E l \in F : StableLeader(l))

\* Every log position a live leader holds is eventually committed by it,
\* unless it stops being a live leader.  Stated per position, so it does
\* not depend on writes being bounded.
WritesCommit ==
  \A l \in F, i \in 1..MaxLogLen :
     (alive[l] /\ role[l] = "Leader" /\ Len(log[l]) >= i)
        ~> (commitIndex[l] >= i \/ ~alive[l] \/ role[l] # "Leader")

-----------------------------------------------------------------------------
(* Coverage witnesses: each must be VIOLATED, which proves the path is     *)
(* reachable.  Checked by check-witnesses.sh with Coverage.cfg.            *)

NoReconfirming == \A f \in F : role[f] # "Reconfirming"

NoLeader == \A f \in F : role[f] # "Leader"

NoArbiterPush == ~\E f \in F : ENABLED ArbiterPushConfig(f)

\* A catches up on a larger proposal number (the fix for finding 3).
NoArbiterAdopt == ~\E f \in F : ENABLED ArbiterAdoptProposal(f)

\* A pushes while some full replica holds a leader role (no lease is
\* assumed).
NoArbiterPushBesideLeader ==
  ~\E f \in F : ENABLED ArbiterPushConfig(f) /\ \E g \in F : role[g] # "Follower"

NoCommittedEntry == committed = {}

\* A degrade committed, and afterwards an entry committed past its barrier.
NoDegradeCommitted ==
  ~\E l \in F : /\ role[l] = "Leader"
                /\ pendingChange[l] = None
                /\ config[l].curr.commitGroup # F
                /\ commitIndex[l] > config[l].barrier.index

\* A new leader confirmed its inherited configuration and is degrading a
\* member during log reconfirmation (the fix for finding 4).
NoDegradeAfterConfirm ==
  ~\E l \in F : /\ role[l] = "Reconfirming"
                /\ pendingChange[l] # None
                /\ pendingChange[l].kind = "Degrade"
                /\ config[l].prev.version[1] = proposal[l]

\* The last committed change re-added a learner, which had to catch up on
\* committed entries first.
NoUpgradeAfterDegrade ==
  ~\E l \in F : /\ role[l] = "Leader"
                /\ pendingChange[l] = None
                /\ config[l].curr.commitGroup = F
                /\ config[l].prev.commitGroup # F
                /\ committed # {}

\* Under a degraded configuration from a smaller proposal number, a leader
\* finished log reconfirmation (its StartWorking log kept the degraded S)
\* with committed entries to recover.
NoReconfirmAfterDegrade ==
  ~\E l \in F : /\ role[l] = "Leader"
                /\ config[l].curr.commitGroup # F
                /\ config[l].prev.commitGroup = config[l].curr.commitGroup
                /\ config[l].prev.version[1] < proposal[l]
                /\ committed # {}

\* Some receiver would discard stale entries on accepting a configuration.
NoStaleTruncate ==
  ~\E l \in F, v \in F :
      /\ ENABLED AcceptConfig(v, l)
      /\ TruncateStaleEntries(v, config[l]) # log[v]

\* A's push (the path the fix for finding 2 changed) would discard stale
\* entries.
NoArbiterStaleTruncate ==
  ~\E f \in F :
      /\ ENABLED ArbiterPushConfig(f)
      /\ TruncateStaleEntries(f, config[A]) # log[f]

\* S shrank to half of F and an entry committed afterwards (in 4F1A this
\* needs two single-member degrades).
NoHalfGroupCommit ==
  ~\E l \in F : /\ role[l] = "Leader"
                /\ pendingChange[l] = None
                /\ Cardinality(config[l].curr.commitGroup) * 2 = Cardinality(F)
                /\ commitIndex[l] > config[l].barrier.index

\* One full replica and A are down, yet a leader commits without any
\* degrade (in 4F1A three full replicas are still a majority of four;
\* unreachable in 2F1A).
NoCommitWithFAndArbiterDown ==
  ~\E l, f \in F : /\ role[l] = "Leader"
                   /\ config[l].curr.commitGroup = F
                   /\ ~alive[f]
                   /\ ~alive[A]
                   /\ commitIndex[l] > config[l].barrier.index

\* The design's liveness boundary: every member of a degraded S is down and
\* a live learner misses committed entries (in 2F1A, S is the single
\* survivor; in 4F1A it is two full replicas).
NoLearnerWindow ==
  ~\E f, g \in F :
      LET S == config[f].curr.commitGroup IN
      /\ f \in S
      /\ S # F
      /\ \A x \in S : ~alive[x]
      /\ alive[g]
      /\ g \notin S
      /\ \E e \in committed : ~HoldsEntry(log[g], e)

\* Liveness scenarios, checked with LiveCoverage.cfg (LiveSpec): each must
\* be VIOLATED, which proves the scenario occurs in the liveness model.

\* A full replica is down and a leader serves (the survivor degraded it).
NoServingAfterFCrash == ~\E l, f \in F : StableLeader(l) /\ ~alive[f]

\* The old leader is down and a new leader serves the entries it committed.
NoServingAfterLeaderCrash ==
  ~\E l, f \in F : /\ StableLeader(l)
                   /\ ~alive[f]
                   /\ \E e \in committed : e.proposal < proposal[l]

\* A is down and a leader serves.
NoServingAfterArbiterCrash == ~\E l \in F : StableLeader(l) /\ ~alive[A]

=============================================================================
