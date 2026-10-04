---------------------------- MODULE Arbitration ----------------------------
(***************************************************************************)
(* PALF with an arbitration replica (2F1A), one log stream.                *)
(*                                                                         *)
(* Grounded in OceanBase src/logservice/palf (github.com/oceanbase/        *)
(* oceanbase, commit 0fa1778).  Names in comments refer to that code.      *)
(*                                                                         *)
(*  - Election members and the prepare quorum are the log-sync list plus   *)
(*    the arbitration replica A (convert_to_complete_config).  Learners    *)
(*    do not vote.                                                         *)
(*  - Log entries commit on a majority of the log-sync list only; A holds  *)
(*    no log and never counts.                                             *)
(*  - The member config is LogConfigMeta in meta storage, not a log entry; *)
(*    it is tied to the log only through its barrier.                      *)
(*  - Election does not compare logs; Phase 1 (reconfirm) recovers them.   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  F,          \* full (data) replicas
  A,          \* the arbitration replica
  None,       \* model value: no config change in flight
  MaxPid,     \* bound on proposal_id
  MaxLogLen,  \* bound on log length
  MaxSeq      \* bound on config_seq, i.e. on the number of config changes

ASSUME A \notin F

Server == F \cup {A}

VARIABLES
  \* persistent: survive a crash
  pid,        \* [Server -> Nat]  proposal_id in the prepare meta
  log,        \* [F -> Seq(Nat)]  entry = pid of the leader that wrote it
  meta,       \* [Server -> Meta] LogConfigMeta: prev/curr config + barrier
  \* volatile: lost on a crash
  alive,      \* [Server -> BOOLEAN]
  role,       \* [F -> {"Follower", "Prepare", "Reconfirm", "Leader"}]
  promises,   \* [F -> SUBSET Server]  prepare_log_ack_list_, incl. self
  cc,         \* [F -> None or [kind, acks]]  in-flight config change
  commitIdx,  \* [F -> Nat]  committed_end_lsn
  \* history, only read by the invariants
  committed   \* SUBSET [idx, pid]

vars == <<pid, log, meta, alive, role, promises, cc, commitIdx, committed>>

-----------------------------------------------------------------------------
(* Helpers *)

Min(a, b) == IF a <= b THEN a ELSE b
Max(a, b) == IF a >= b THEN a ELSE b
SetMax(S) == CHOOSE x \in S : \A y \in S : y <= x

IsMajority(S, T) == Cardinality(S \cap T) * 2 > Cardinality(T)

\* convert_to_complete_config: log_sync_memberlist + arbitration_member.
ElectionMembers(s) == meta[s].curr.sync \cup {A}

LastLogPid(lg) == IF lg = << >> THEN 0 ELSE lg[Len(lg)]

\* The proposal_id a replica reports in its prepare response: the larger of
\* its last log's pid and its config meta's pid (submit_prepare_log_, which
\* explains why: otherwise ghost logs could be recovered).
AcceptedPid(f) == Max(LastLogPid(log[f]), meta[f].curr.ver[1])

\* LogConfigVersion = (proposal_id, config_seq), compared lexicographically.
VersionLT(v1, v2) == \/ v1[1] < v2[1]
                     \/ v1[1] = v2[1] /\ v1[2] < v2[2]
VersionLE(v1, v2) == VersionLT(v1, v2) \/ v1 = v2

IsPrefix(a, b) == Len(a) <= Len(b) /\ SubSeq(b, 1, Len(a)) = a

LogCaughtUp(f, lg) == IsPrefix(lg, log[f])

\* pre_check_for_config_log: the receiver's log matches at the barrier.
\* (IF, not \/: inside an action TLC evaluates every disjunct.)
PassesBarrier(f, m) ==
  IF m.barrier.idx = 0
  THEN TRUE
  ELSE /\ Len(log[f]) >= m.barrier.idx
       /\ log[f][m.barrier.idx] = m.barrier.pid

\* pre_check_for_config_log: once the barrier matches, if the next log has a
\* smaller pid than the meta's own proposal_id, everything after the barrier
\* is a ghost log and is truncated.
\*
\* FIX (see findings.md, finding 2): the code compares with the message's
\* proposal_id.  That equals the meta's proposal_id when a leader sends its
\* own meta, but not when A (sync_meta_for_arb_election_leader) forwards an
\* older meta with its current, larger proposal_id; then committed logs that
\* the meta's leader wrote after the barrier were truncated.  The model
\* compares with the meta's proposal_id (meta.proposal_id_ ==
\* curr.ver[1]), which leaves the leader's own path unchanged.
LogAfterMeta(f, m) ==
  IF Len(log[f]) > m.barrier.idx /\ log[f][m.barrier.idx + 1] < m.curr.ver[1]
  THEN SubSeq(log[f], 1, m.barrier.idx)
  ELSE log[f]

\* Q could elect c: c is in Q, Q is a majority of c's election members, and
\* no voter has a newer membership version (ElectionAcceptor::
\* on_prepare_request ignores requests with a lower membership_version).
ElectableBy(c, Q) ==
  /\ c \in Q
  /\ Q \subseteq ElectionMembers(c)
  /\ IsMajority(Q, ElectionMembers(c))
  /\ \A v \in Q : VersionLE(meta[v].curr.ver, meta[c].curr.ver)

CanBeElected(c) ==
  \E Q \in SUBSET ElectionMembers(c) :
     ElectableBy(c, Q) /\ \A v \in Q : alive[v]

\* The F replicas in Q with the largest (AcceptedPid, log length): Phase 1
\* fetches the log from one of them.  A is never a log source.
MaxLogServers(Q) ==
  { m \in Q \cap F :
      \A f \in Q \cap F :
         \/ AcceptedPid(f) < AcceptedPid(m)
         \/ AcceptedPid(f) = AcceptedPid(m) /\ Len(log[f]) <= Len(log[m]) }

\* The meta a leader proposes: version (its pid, seq + 1) and a barrier at
\* the end of its log (append_config_meta_, renew_config_change_barrier_).
NextMeta(l, sync) ==
  [prev    |-> meta[l].curr,
   curr    |-> [ver |-> <<pid[l], meta[l].curr.ver[2] + 1>>, sync |-> sync],
   barrier |-> [idx |-> Len(log[l]), pid |-> LastLogPid(log[l])]]

\* A majority of S already holds the leader's log (wait_log_barrier_,
\* check_follower_sync_status_, is_accept_quorum_catch_up_).
MajorityCaughtUp(l, S) == IsMajority({f \in S : LogCaughtUp(f, log[l])}, S)

Entries(lg, n) == { [idx |-> j, pid |-> lg[j]] : j \in 1..n }

Has(lg, e) == Len(lg) >= e.idx /\ lg[e.idx] = e.pid

\* A replica that learns a larger proposal_id leaves any leader role
\* (LogStateMgr::handle_prepare_request).
Demoted(v, p) == v \in F /\ role[v] # "Follower" /\ pid[v] < p

RoleAfter(v, p)     == [x \in F |-> IF x = v /\ Demoted(v, p) THEN "Follower" ELSE role[x]]
PromisesAfter(v, p) == [x \in F |-> IF x = v /\ Demoted(v, p) THEN {} ELSE promises[x]]
CcAfter(v, p)       == [x \in F |-> IF x = v /\ Demoted(v, p) THEN None ELSE cc[x]]

\* try_update_proposal_id_ + can_receive_config_log.  A skips the barrier.
CanReceiveMeta(v, m, p) ==
  /\ alive[v]
  /\ pid[v] <= p
  /\ VersionLE(meta[v].curr.ver, m.curr.ver)
  /\ v \in F => PassesBarrier(v, m)

-----------------------------------------------------------------------------
(* Initial state *)

InitCfg  == [ver |-> <<0, 0>>, sync |-> F]
InitMeta == [prev |-> InitCfg, curr |-> InitCfg, barrier |-> [idx |-> 0, pid |-> 0]]

Init ==
  /\ pid       = [s \in Server |-> 0]
  /\ log       = [f \in F |-> << >>]
  /\ meta      = [s \in Server |-> InitMeta]
  /\ alive     = [s \in Server |-> TRUE]
  /\ role      = [f \in F |-> "Follower"]
  /\ promises  = [f \in F |-> {}]
  /\ cc        = [f \in F |-> None]
  /\ commitIdx = [f \in F |-> 0]
  /\ committed = {}

-----------------------------------------------------------------------------
(* Election and Phase 1 (reconfirm, log_reconfirm.cpp) *)

\* The election (palf/election) picks c without comparing logs; c then
\* starts Phase 1 with a larger proposal_id (LogReconfirm::
\* submit_prepare_log_).  The election lease is not modelled, so several
\* election leaders may coexist; safety must rest on proposal_id alone.
Elect(c, b) ==
  /\ alive[c]
  /\ role[c] \in {"Follower", "Prepare"}
  /\ c \in meta[c].curr.sync     \* ElectionProposer gives up if not a member
  /\ CanBeElected(c)
  /\ pid[c] < b
  /\ pid'      = [pid EXCEPT ![c] = b]
  /\ role'     = [role EXCEPT ![c] = "Prepare"]
  /\ promises' = [promises EXCEPT ![c] = {c}]
  /\ cc'       = [cc EXCEPT ![c] = None]
  /\ UNCHANGED <<log, meta, alive, commitIdx, committed>>

\* v promises c's proposal_id (LogStateMgr::handle_prepare_request).  c runs
\* prepare only while it holds the election, and v backs c's election only
\* if c's membership version is not lower than its own (ElectionAcceptor
\* ignores lower membership_version), so v filters by config version here.
Promise(v, c) ==
  /\ role[c] = "Prepare"
  /\ alive[c]
  /\ alive[v]
  /\ v \in ElectionMembers(c) \ {c}
  /\ VersionLE(meta[v].curr.ver, meta[c].curr.ver)
  /\ pid[v] < pid[c]
  /\ pid'      = [pid EXCEPT ![v] = pid[c]]
  /\ role'     = RoleAfter(v, pid[c])
  /\ promises' = [x \in F |-> IF x = c THEN promises[c] \cup {v}
                              ELSE IF x = v /\ Demoted(v, pid[c]) THEN {}
                              ELSE promises[x]]
  /\ cc'       = CcAfter(v, pid[c])
  /\ UNCHANGED <<log, meta, alive, commitIdx, committed>>

\* With a prepare quorum, fetch the log of a replica with the largest
\* (AcceptedPid, length) (FETCH_MAX_LOG_LSN, RECONFIRM_FETCH_LOG).
Fetch(c) ==
  /\ role[c] = "Prepare"
  /\ alive[c]
  /\ IsMajority(promises[c], ElectionMembers(c))
  /\ \E m \in MaxLogServers(promises[c]) :
        /\ alive[m]
        /\ log' = [log EXCEPT ![c] = log[m]]
  /\ role' = [role EXCEPT ![c] = "Reconfirm"]
  /\ UNCHANGED <<pid, meta, alive, promises, cc, commitIdx, committed>>

-----------------------------------------------------------------------------
(* Phase 2: config changes (log_config_mgr.cpp).  The config is a        *)
(* LogConfigMeta in meta storage; it commits on a majority of the NEW    *)
(* election members (log-sync list + A).                                 *)

\* The leader rewrites its own meta first, then sends it
\* (append_config_meta_).
ProposeConfig(l, sync, kind) ==
  /\ meta' = [meta EXCEPT ![l] = NextMeta(l, sync)]
  /\ cc'   = [cc EXCEPT ![l] = [kind |-> kind, acks |-> {l}]]
  /\ UNCHANGED <<pid, log, alive, role, promises, commitIdx, committed>>

CanPropose(l) ==
  /\ alive[l]
  /\ cc[l] = None
  /\ meta[l].curr.ver[2] < MaxSeq

\* START_WORKING (confirm_start_working_log): re-commit the current member
\* list at the new proposal_id once a majority of the log-sync list holds
\* the recovered log (is_accept_quorum_catch_up_).
StartWorking(l) ==
  /\ role[l] = "Reconfirm"
  /\ CanPropose(l)
  /\ MajorityCaughtUp(l, meta[l].curr.sync)
  /\ ProposeConfig(l, meta[l].curr.sync, "StartWorking")

\* Turn exactly half of F into learners (degrade_acceptor_to_learner).
\* Allowed in reconfirm once the log is fetched (can_do_degrade).  S may
\* contain live replicas: failure detection can be wrong.
Degrade(l, S) ==
  /\ role[l] \in {"Reconfirm", "Leader"}
  /\ CanPropose(l)
  /\ meta[l].curr.sync = F
  /\ S \subseteq F \ {l}
  /\ Cardinality(S) * 2 = Cardinality(F)
  /\ MajorityCaughtUp(l, F \ S)
  /\ ProposeConfig(l, F \ S, "Degrade")

\* Turn a learner whose log equals the leader's back into a log-sync
\* member (upgrade_learner_to_acceptor).
Upgrade(l, m) ==
  /\ role[l] = "Leader"
  /\ CanPropose(l)
  /\ m \in F \ meta[l].curr.sync
  /\ alive[m]
  /\ log[m] = log[l]
  /\ MajorityCaughtUp(l, meta[l].curr.sync \cup {m})
  /\ ProposeConfig(l, meta[l].curr.sync \cup {m}, "Upgrade")

\* Leader l sends its meta to v (submit_config_log_ / receive_config_log):
\* either the in-flight change, or a resend of the current config to a
\* replica that is behind.  Learners receive it too, but only the new
\* members' acks count.
SendMeta(v, l) ==
  /\ l \in F
  /\ alive[l]
  /\ v # l
  /\ \/ cc[l] # None /\ v \notin cc[l].acks
     \/ /\ role[l] = "Leader"
        /\ cc[l] = None
        /\ VersionLT(meta[v].curr.ver, meta[l].curr.ver)
  /\ CanReceiveMeta(v, meta[l], pid[l])
  /\ pid'      = [pid EXCEPT ![v] = pid[l]]
  /\ meta'     = [meta EXCEPT ![v] = meta[l]]
  /\ log'      = IF v \in F
                   THEN [log EXCEPT ![v] = LogAfterMeta(v, meta[l])]
                   ELSE log
  /\ role'     = RoleAfter(v, pid[l])
  /\ promises' = PromisesAfter(v, pid[l])
  /\ cc'       = [x \in F |-> IF x = l /\ cc[l] # None
                                THEN [cc[l] EXCEPT !.acks = @ \cup {v}]
                              ELSE IF x = v /\ Demoted(v, pid[l]) THEN None
                              ELSE cc[x]]
  /\ UNCHANGED <<alive, commitIdx, committed>>

\* The change commits once a majority of the NEW election members persisted
\* it (is_reach_majority_).  Committing START_WORKING ends reconfirm and
\* commits the recovered log up to the barrier (saved_end_lsn_).
CommitConfig(l) ==
  /\ alive[l]
  /\ cc[l] # None
  /\ IsMajority(cc[l].acks, ElectionMembers(l))
  /\ cc' = [cc EXCEPT ![l] = None]
  /\ IF cc[l].kind = "StartWorking"
       THEN /\ role'      = [role EXCEPT ![l] = "Leader"]
            /\ commitIdx' = [commitIdx EXCEPT ![l] = meta[l].barrier.idx]
            /\ committed' = committed \cup Entries(log[l], meta[l].barrier.idx)
       ELSE UNCHANGED <<role, commitIdx, committed>>
  /\ UNCHANGED <<pid, log, meta, alive, promises>>

\* When A is the election leader it pushes its meta to the F replicas
\* (sync_meta_for_arb_election_leader); A never runs Phase 1.  The message
\* carries A's current proposal_id with the barrier of A's meta
\* (pre_sync_config_log_and_mode_meta_).  Since A holds the election, no F
\* holds a PALF leader role (that role follows the election role).
ArbPush(f) ==
  /\ alive[A]
  /\ CanBeElected(A)
  /\ \A g \in F : role[g] = "Follower"
  /\ VersionLT(meta[f].curr.ver, meta[A].curr.ver)
  /\ CanReceiveMeta(f, meta[A], pid[A])
  /\ pid'  = [pid EXCEPT ![f] = pid[A]]
  /\ meta' = [meta EXCEPT ![f] = meta[A]]
  /\ log'  = [log EXCEPT ![f] = LogAfterMeta(f, meta[A])]
  /\ UNCHANGED <<alive, role, promises, cc, commitIdx, committed>>

-----------------------------------------------------------------------------
(* Phase 2: the log (log_sliding_window.cpp) *)

\* Writes are allowed while a config change is in flight; only the commit
\* point is frozen (gen_committed_end_lsn_).
Write(l) ==
  /\ alive[l]
  /\ role[l] = "Leader"
  /\ Len(log[l]) < MaxLogLen
  /\ log' = [log EXCEPT ![l] = Append(@, pid[l])]
  /\ UNCHANGED <<pid, meta, alive, role, promises, cc, commitIdx, committed>>

FirstDiff(a, b) ==
  CHOOSE i \in 1..Min(Len(a), Len(b)) :
     /\ a[i] # b[i]
     /\ \A j \in 1..(i - 1) : a[j] = b[j]

\* f receives one step of l's log: append the next entry when f's log is a
\* prefix of l's, or drop f's suffix from the first conflict.  The receiver
\* adopts l's proposal_id (try_update_proposal_id_, can_receive_log).
\* Learners receive logs too.
Replicate(f, l) ==
  /\ f # l
  /\ alive[f]
  /\ alive[l]
  /\ role[l] \in {"Reconfirm", "Leader"}
  /\ pid[f] <= pid[l]
  /\ \/ /\ IsPrefix(log[f], log[l])
        /\ Len(log[f]) < Len(log[l])
        /\ log' = [log EXCEPT ![f] = Append(log[f], log[l][Len(log[f]) + 1])]
     \/ /\ \E i \in 1..Min(Len(log[f]), Len(log[l])) : log[f][i] # log[l][i]
        /\ log' = [log EXCEPT ![f] = SubSeq(log[f], 1, FirstDiff(log[f], log[l]) - 1)]
  /\ pid'      = [pid EXCEPT ![f] = pid[l]]
  /\ role'     = RoleAfter(f, pid[l])
  /\ promises' = PromisesAfter(f, pid[l])
  /\ cc'       = CcAfter(f, pid[l])
  /\ UNCHANGED <<meta, alive, commitIdx, committed>>

\* Position i is acknowledged by a majority of T (match_lsn_map_).
AckedBy(l, i, T) ==
  IsMajority({f \in T : /\ Len(log[f]) >= i
                        /\ SubSeq(log[f], 1, i) = SubSeq(log[l], 1, i)}, T)

\* gen_committed_end_lsn_: before the barrier either the previous or the
\* current log-sync list may commit, capped at the barrier; after it only
\* the current list.  A never counts.
CanCommitUpTo(l, i) ==
  LET b == meta[l].barrier.idx IN
  IF commitIdx[l] < b
  THEN /\ i <= b
       /\ AckedBy(l, i, meta[l].prev.sync) \/ AckedBy(l, i, meta[l].curr.sync)
  ELSE AckedBy(l, i, meta[l].curr.sync)

\* No commit while a config change with A is in flight
\* (is_changing_config_with_arb).
CommitLog(l, i) ==
  /\ alive[l]
  /\ role[l] = "Leader"
  /\ cc[l] = None
  /\ commitIdx[l] < i
  /\ i <= Len(log[l])
  /\ CanCommitUpTo(l, i)
  /\ commitIdx' = [commitIdx EXCEPT ![l] = i]
  /\ committed' = committed \cup Entries(log[l], i)
  /\ UNCHANGED <<pid, log, meta, alive, role, promises, cc>>

-----------------------------------------------------------------------------
(* Failures.  A crash keeps pid, log and meta and drops everything else.  *)
(* A partition needs no action: steps between the two sides simply do not *)
(* happen, and a partitioned leader keeps acting on its own.              *)

Crash(s) ==
  /\ alive[s]
  /\ alive' = [alive EXCEPT ![s] = FALSE]
  /\ IF s \in F
       THEN /\ role'      = [role EXCEPT ![s] = "Follower"]
            /\ promises'  = [promises EXCEPT ![s] = {}]
            /\ cc'        = [cc EXCEPT ![s] = None]
            /\ commitIdx' = [commitIdx EXCEPT ![s] = 0]
       ELSE UNCHANGED <<role, promises, cc, commitIdx>>
  /\ UNCHANGED <<pid, log, meta, committed>>

Restart(s) ==
  /\ ~alive[s]
  /\ alive' = [alive EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<pid, log, meta, role, promises, cc, commitIdx, committed>>

-----------------------------------------------------------------------------
(* Next-state relation *)

Next ==
  \/ \E c \in F, b \in 1..MaxPid    : Elect(c, b)
  \/ \E c \in F, v \in Server       : Promise(v, c)
  \/ \E c \in F                     : Fetch(c)
  \/ \E l \in F                     : StartWorking(l)
  \/ \E l \in F, S \in SUBSET F     : Degrade(l, S)
  \/ \E l, m \in F                  : Upgrade(l, m)
  \/ \E l \in F, v \in Server       : SendMeta(v, l)
  \/ \E l \in F                     : CommitConfig(l)
  \/ \E f \in F                     : ArbPush(f)
  \/ \E l \in F                     : Write(l)
  \/ \E f, l \in F                  : Replicate(f, l)
  \/ \E l \in F, i \in 1..MaxLogLen : CommitLog(l, i)
  \/ \E s \in Server                : Crash(s) \/ Restart(s)

Spec == Init /\ [][Next]_vars

Symmetry == Permutations(F)

-----------------------------------------------------------------------------
(* Safety *)

CfgType  == [ver : (0..MaxPid) \X (0..MaxSeq), sync : SUBSET F]
MetaType == [prev : CfgType, curr : CfgType,
             barrier : [idx : 0..MaxLogLen, pid : 0..MaxPid]]

TypeOK ==
  /\ pid       \in [Server -> 0..MaxPid]
  /\ log       \in [F -> Seq(1..MaxPid)]
  /\ \A f \in F : Len(log[f]) <= MaxLogLen
  /\ meta      \in [Server -> MetaType]
  /\ alive     \in [Server -> BOOLEAN]
  /\ role      \in [F -> {"Follower", "Prepare", "Reconfirm", "Leader"}]
  /\ promises  \in [F -> SUBSET Server]
  /\ cc        \in [F -> {None} \cup [kind : {"StartWorking", "Degrade", "Upgrade"},
                                       acks : SUBSET Server]]
  /\ commitIdx \in [F -> 0..MaxLogLen]
  /\ committed \subseteq [idx : 1..MaxLogLen, pid : 1..MaxPid]

\* At most one replica leads (past the prepare quorum) at each proposal_id.
OneLeaderPerPid ==
  \A l1, l2 \in F :
     /\ l1 # l2
     /\ role[l1] \in {"Reconfirm", "Leader"}
     /\ role[l2] \in {"Reconfirm", "Leader"}
     => pid[l1] # pid[l2]

LogMatching ==
  \A f1, f2 \in F :
     \A i \in 1..Min(Len(log[f1]), Len(log[f2])) :
        log[f1][i] = log[f2][i] => SubSeq(log[f1], 1, i) = SubSeq(log[f2], 1, i)

\* I1: any F that could finish Phase 1 recovers every committed entry: the
\* metadata quorum always meets a data replica holding the committed log.
QuorumIntersection ==
  \A c \in F :
     c \in meta[c].curr.sync =>
        \A Q \in SUBSET ElectionMembers(c) :
           ElectableBy(c, Q) =>
              \A m \in MaxLogServers(Q) : \A e \in committed : Has(log[m], e)

\* I2b: at most one leader can advance the commit point.
AbleToCommit(l) ==
  /\ role[l] = "Leader"
  /\ cc[l] = None
  /\ IsMajority({f \in meta[l].curr.sync : pid[f] <= pid[l]}, meta[l].curr.sync)

NoDualPrimary ==
  \A l1, l2 \in F : AbleToCommit(l1) /\ AbleToCommit(l2) => l1 = l2

\* I3a: one LSN is never committed with two different proposal_ids.
CommittedConsistent ==
  \A e1, e2 \in committed : e1.idx = e2.idx => e1.pid = e2.pid

\* I3b: a leader holds every committed entry whose pid is not above its own.
LeaderCompleteness ==
  \A l \in F :
     role[l] = "Leader" =>
        \A e \in committed : e.pid <= pid[l] => Has(log[l], e)

CommittedMonotonic == [][committed \subseteq committed']_vars

\* I4: A's config is never ahead of what a majority of its log-sync list
\* can catch up to, either because they already have it or because their
\* log passes its barrier (so they can accept it from A).
ArbNotAhead ==
  LET m == meta[A] IN
  IsMajority({f \in m.curr.sync : \/ VersionLE(m.curr.ver, meta[f].curr.ver)
                                  \/ PassesBarrier(f, m)},
             m.curr.sync)

PidMonotonic == [][\A s \in Server : pid'[s] >= pid[s]]_vars

ConfigVersionMonotonic ==
  [][\A s \in Server : VersionLE(meta[s].curr.ver, meta'[s].curr.ver)]_vars

-----------------------------------------------------------------------------
(* Liveness: a minority failure never stops service.                      *)
(*                                                                         *)
(* Environment assumptions, used only here (Spec makes none of them):     *)
(*  - failures are permanent and always a minority of Server;             *)
(*  - the election eventually stabilizes: nobody campaigns while another  *)
(*    live F is past Follower, and a candidate retries only when stuck,   *)
(*    with a proposal_id above every live replica's;                      *)
(*  - failure detection is eventually accurate: only dead F are degraded; *)
(*  - weak fairness for every protocol step except client writes.          *)

Down == {s \in Server : ~alive[s]}

CrashLive(s) == Crash(s) /\ Cardinality(Down \cup {s}) * 2 < Cardinality(Server)

NextPid == 1 + SetMax({pid[s] : s \in Server \ Down})

OthersFollow(c) == \A f \in F \ {c} : ~alive[f] \/ role[f] = "Follower"

\* c cannot finish Phase 1: Fetch is impossible and no more promises can come.
PrepareStuck(c) ==
  /\ role[c] = "Prepare"
  /\ ~(/\ IsMajority(promises[c], ElectionMembers(c))
       /\ \E m \in MaxLogServers(promises[c]) : alive[m])
  /\ {v \in ElectionMembers(c) \ promises[c] :
        alive[v] /\ pid[v] < pid[c] /\ VersionLE(meta[v].curr.ver, meta[c].curr.ver)} = {}

ElectLive(c) ==
  /\ OthersFollow(c)
  /\ role[c] = "Follower" \/ PrepareStuck(c)
  /\ NextPid <= MaxPid
  /\ Elect(c, NextPid)

DegradeLive(l) == Degrade(l, {f \in meta[l].curr.sync : ~alive[f]})

LiveNext ==
  \/ \E c \in F                     : ElectLive(c)
  \/ \E c \in F, v \in Server       : Promise(v, c)
  \/ \E c \in F                     : Fetch(c)
  \/ \E l \in F                     : StartWorking(l)
  \/ \E l \in F                     : DegradeLive(l)
  \/ \E l \in F, v \in Server       : SendMeta(v, l)
  \/ \E l \in F                     : CommitConfig(l)
  \/ \E f \in F                     : ArbPush(f)
  \/ \E l \in F                     : Write(l)
  \/ \E f, l \in F                  : Replicate(f, l)
  \/ \E l \in F, i \in 1..MaxLogLen : CommitLog(l, i)
  \/ \E s \in Server                : CrashLive(s)

Fairness ==
  /\ \A c \in F                     : WF_vars(ElectLive(c))
  /\ \A c \in F, v \in Server       : WF_vars(Promise(v, c))
  /\ \A c \in F                     : WF_vars(Fetch(c))
  /\ \A l \in F                     : WF_vars(StartWorking(l))
  /\ \A l \in F                     : WF_vars(DegradeLive(l))
  /\ \A l \in F, v \in Server       : WF_vars(SendMeta(v, l))
  /\ \A l \in F                     : WF_vars(CommitConfig(l))
  /\ \A f \in F                     : WF_vars(ArbPush(f))
  /\ \A f, l \in F                  : WF_vars(Replicate(f, l))
  /\ \A l \in F, i \in 1..MaxLogLen : WF_vars(CommitLog(l, i))

LiveSpec == Init /\ [][LiveNext]_vars /\ Fairness

\* A leader whose log-sync list has a live majority and that has committed
\* everything it wrote.
Serving(l) ==
  /\ alive[l]
  /\ role[l] = "Leader"
  /\ cc[l] = None
  /\ IsMajority({f \in meta[l].curr.sync : alive[f]}, meta[l].curr.sync)
  /\ commitIdx[l] = Len(log[l])

EventuallyServing == <>[](\E l \in F : Serving(l))

-----------------------------------------------------------------------------
(* Coverage witnesses: each must be VIOLATED, which proves the path is    *)
(* reachable.  Checked by check-witnesses.sh with Coverage.cfg.           *)

NoReconfirm == \A f \in F : role[f] # "Reconfirm"

NoLeader == \A f \in F : role[f] # "Leader"

NoArbPush == ~\E f \in F : ENABLED ArbPush(f)

NoCommittedEntry == committed = {}

\* A degrade committed, and afterwards a new log committed past its barrier.
NoDegradeCommitted ==
  ~\E l \in F : /\ role[l] = "Leader"
                /\ cc[l] = None
                /\ meta[l].curr.sync # F
                /\ commitIdx[l] > meta[l].barrier.idx

\* The last committed change re-added a learner, which had to catch up on
\* committed logs first.
NoUpgradeAfterDegrade ==
  ~\E l \in F : /\ role[l] = "Leader"
                /\ cc[l] = None
                /\ meta[l].curr.sync = F
                /\ meta[l].prev.sync # F
                /\ committed # {}

\* Under a degraded config from an earlier proposal_id, a leader finished
\* reconfirm (its START_WORKING kept the degraded list) with committed logs
\* to recover.
NoReconfirmAfterDegrade ==
  ~\E l \in F : /\ role[l] = "Leader"
                /\ meta[l].curr.sync # F
                /\ meta[l].prev.sync = meta[l].curr.sync
                /\ meta[l].prev.ver[1] < pid[l]
                /\ committed # {}

\* Some receiver would truncate ghost logs on accepting a config.
NoGhostTruncate ==
  ~\E l \in F, v \in F :
      /\ ENABLED SendMeta(v, l)
      /\ LogAfterMeta(v, meta[l]) # log[v]

\* The design's liveness boundary: the only log-sync F is down and a live
\* learner misses committed logs.
NoLearnerWindow ==
  ~\E f, g \in F :
      /\ ~alive[f]
      /\ alive[g]
      /\ meta[f].curr.sync = {f}
      /\ \E e \in committed : ~Has(log[g], e)

\* Liveness scenarios, checked with LiveCoverage.cfg (LiveSpec): each must be
\* VIOLATED, which proves the scenario occurs in the liveness model.

\* An F is down and a leader serves (the survivor degraded it).
NoServingAfterFCrash == ~\E l, f \in F : Serving(l) /\ ~alive[f]

\* The old leader is down and a new leader serves the entries it committed.
NoServingAfterLeaderCrash ==
  ~\E l, f \in F : /\ Serving(l)
                   /\ ~alive[f]
                   /\ \E e \in committed : e.pid < pid[l]

\* A is down and a leader serves.
NoServingAfterArbCrash == ~\E l \in F : Serving(l) /\ ~alive[A]

=============================================================================
