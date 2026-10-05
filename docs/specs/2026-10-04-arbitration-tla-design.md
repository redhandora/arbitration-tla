# 2F1A 仲裁副本 TLA+ 模型设计

日期：2026-10-04（第二版）
状态：已实现，结果见 `arbitration/results.md`，发现的问题见 `arbitration/findings.md`

## 1. 目的和范围

- **目的：** 为仲裁论文的 TLA+ 和证明部分提供一份可以模型检查的规格，证明 PALF 在仲裁副本（A）参与下：
  - 满足一组安全性不变式；
  - 满足活性：少数派异常时，系统总能恢复服务。
- **建模对象：** 单个日志流，F 的个数可配；检查了 2F1A 和 4F1A。
- **依据：** OceanBase 源码 `src/logservice/palf/`（GitHub，提交 `0fa1778`，2026-09-30）。A 侧代码不在开源仓库里，相关行为按作者确认的三条假设建模（见 §6）。
- **范围内：** 选举、Phase 1（reconfirm）、Phase 2（日志和配置）、degrade、upgrade、START_WORKING、A 作为选举 leader 推送配置、F 和 A 的崩溃与重启。
- **范围外：** add / remove / replace 成员、flashback（mode meta）、租约读、磁盘永久丢失、F 数为奇数的部署。

## 2. 仲裁的核心思路，以及模型怎么体现

以 2F1A 为例：
- **选举用 3 个副本**（F1、F2、A），多数派是 2 个。
- **同步只用 2 个数据副本**（F1、F2），多数派是 2 个，也就是两个 F 都要。

挂掉一个 F 之后：
1. 剩下的 F 加上 A，仍然是 3 个里的 2 个，可以完成选举和 Phase 1。
2. 再把挂掉的 F 从同步列表里删掉（degrade，它变成 learner），同步列表只剩 1 个 F，它自己就是多数派，可以继续提交日志。

模型中对应的定义：

| 思路 | 模型里的定义 |
|---|---|
| 选举成员 = 同步列表 + A | `ElectionMembers(s) == meta[s].curr.sync \cup {A}` |
| 日志提交只看同步列表，A 不算 | `CommitLog` 只在 `curr.sync` 上计算多数派 |
| 挂掉一个 F 后，剩下的 F + A 能选出 leader | `CanBeElected`、`Promise`、`Fetch` 都按 `ElectionMembers` 计算多数派 |
| 删掉挂掉的 F | `Degrade`，每次去掉一个成员，最终 `sync` 只剩幸存的 F |

**为什么 A 没有日志也安全：** 2F1A 的同步多数派是全部 F，所以已提交的日志一定在每个同步列表里的 F 上。任何选举多数派里至少有一个这样的 F，Phase 1 从它那里就能拉到完整日志。不变式 I1 检查的就是这一点。

## 3. 关键决定

1. **独立模块**，不依赖压缩包里的 `PalfBase.tla`。
2. **没有规则开关。** 模型就是"协议本身 + 不变式 + 活性"，代码里不出现 `Rules` 常量、`NoRuleN.cfg` 或 R1–R5 标签。动作和检查按源码命名，注释只写源码出处。
3. **共享状态模型：** 每个动作是一个副本读取另一个副本的当前状态。消息丢失表示动作不发生；乱序由任意交错产生。
4. **选举不看日志**，日志的安全性靠 Phase 1 恢复。安全性模型里不建模选举的 lease 和 ballot，允许多个选举 leader 同时存在。配置路径的安全性依靠 Phase 1 的配置版本过滤（`Promise`），见 `arbitration/findings.md` 问题 1。
5. **配置存在 meta 存储里，不在日志里。** 它和日志的唯一联系是 barrier。
6. **learner 不参与投票。** 选举和 prepare 的成员列表都是 `sync + A`。不区分 degraded learner 和普通 learner，统一叫 learner。
7. **语言：** 文档用中文；`.tla` 里的注释用英文，因为它要随论文公开。

对 `craft/tla/README.md` 的影响：README 原计划有 `NoRuleN.cfg` 和反例实验，按第 2 条不再做。README 和 `content/06-tla-plus.md` 需要以后同步修改，这次不动。

## 4. 常量和状态

### 常量

| 常量 | 含义 | 默认值 |
|---|---|---|
| `F` | 数据副本集合 | `{f1, f2}` |
| `A` | 仲裁副本 | `a` |
| `MaxPid` | proposal_id 上限 | 3 |
| `MaxLogLen` | 日志长度上限 | 2 |
| `MaxSeq` | 配置 seq 上限，用来限制配置变更次数 | 4 |

`Server == F \cup {A}`。日志条目只记写入时 leader 的 pid，下标就是 LSN。

### 持久化状态（崩溃后保留）

| 变量 | 定义域 | 含义 | 源码 |
|---|---|---|---|
| `pid` | Server | prepare meta 里的 proposal_id | `LogStateMgr::get_proposal_id` |
| `log` | **只有 F** | `Seq(pid)` | sliding window 和日志存储 |
| `meta` | Server | `[prev, curr, barrier]` | `LogConfigMeta`（`log_ms_meta_`） |

- `prev` 和 `curr` 的结构都是 `[ver |-> <<pid, seq>>, sync |-> SUBSET F]`。`ver` 对应 `LogConfigVersion`，按字典序比较；`sync` 对应 `log_sync_memberlist_`。
- learner 就是 `F \ curr.sync`。
- `barrier = [idx, pid]` 对应 `prev_lsn_` 和 `prev_log_proposal_id_`，指向日志里的一个位置；`idx = 0` 表示空日志。
- A 只有 `pid` 和 `meta`，没有 `log`，所以"A 不存日志"由构造保证。

### 易失状态（崩溃后清空）

| 变量 | 定义域 | 含义 |
|---|---|---|
| `alive` | Server | 是否存活，见 §4.1 |
| `role` | F | `Follower`、`Prepare`、`Reconfirm`、`Leader` 之一 |
| `promises` | F | Phase 1 收到的应答集合（`prepare_log_ack_list_`，含自己） |
| `pq` | F | `Elect` 时固定下来的 `[mem, ver]`：prepare 名单（`init_reconfirm_` 里的 `curr_paxos_follower_list_` 加自己）和发起这一轮选举时的配置版本。`Promise` 和 `Fetch` 按名单计算多数派，`Promise` 的版本过滤也用这个版本（候选在 prepare 中途从同 pid 的另一个 leader 接受的配置，不会让它这一轮的选举变新）；离开 Prepare、退位或崩溃时清空 |
| `cc` | F | 进行中的配置变更 `[kind, acks]`，或 `None`。`kind` 取 `StartWorking`、`Degrade`、`Upgrade` 之一（`ConfigChangeState` 和 `ms_ack_list_`） |
| `commitIdx` | F | leader 的 committed_end_lsn |

**`role` 的含义：**

| 值 | 含义 | 对应源码的 reconfirm 状态 |
|---|---|---|
| `Follower` | 普通副本 | — |
| `Prepare` | 已发出 prepare，正在收集 promise | WAITING_LOG_FLUSHED、FETCH_MAX_LOG_LSN |
| `Reconfirm` | 已拉完日志，等日志多数派追上，然后提交 START_WORKING | RECONFIRM_FETCH_LOG 之后，到 START_WORKING |
| `Leader` | reconfirm 完成，开始服务 | FINISHED |

**历史变量：** `committed` 是所有已提交的 `[idx, pid]` 集合，只用于检查不变式。

### 4.1 `alive` 怎么建模

- **崩溃 `Crash(s)`：** `alive[s] := FALSE`，并清空 s 的易失状态（`role` 回到 `Follower`，`promises`、`pq`、`cc`、`commitIdx` 清空）。持久化状态 `pid`、`log`、`meta` 保留。
- **重启 `Restart(s)`：** `alive[s] := TRUE`，从持久化状态继续。
- **宕机期间：** 所有动作都要求参与方存活，所以宕机的副本既不发消息，也不收消息。
- **网络分区不单独建模。** 共享状态模型里，任何两个副本之间的动作都可以一直不发生，分区就等于"这些动作没发生"。被分区隔开的旧 leader 仍然存活、保留易失状态，还能在本地写日志，这正是"租约过期但旧 leader 还在写"的最坏情况。
- **`alive` 的作用：**
  - 在安全性检查里，它只用来区分"崩溃丢失易失状态"和"仅仅没有通信"。
  - 在活性检查里，它定义"哪些副本异常"（崩溃和被隔离按同样处理）。

### 初始状态

- 所有副本 `pid = 0`、存活。
- 所有 F 的日志为空、`role = Follower`。
- 所有副本 `meta = [prev = curr = [ver = <<0,0>>, sync = F], barrier = [idx = 0, pid = 0]]`。
- `committed = {}`。

## 5. 辅助定义

```
IsMajority(S, T)        == Cardinality(S \cap T) * 2 > Cardinality(T)
ElectionMembers(s)      == meta[s].curr.sync \cup {A}           \* convert_to_complete_config
LastLogPid(lg)          == IF lg = << >> THEN 0 ELSE lg[Len(lg)]
AcceptedPid(f)          == Max(LastLogPid(log[f]), meta[f].curr.ver[1])
                           \* submit_prepare_log_ 的注释：防 ghost log
VersionLE(v1, v2)       == 字典序 v1 <= v2
PassesBarrier(f, m)     == m.barrier.idx = 0
                           \/ (Len(log[f]) >= m.barrier.idx
                               /\ log[f][m.barrier.idx] = m.barrier.pid)
                           \* pre_check_for_config_log
LogCaughtUp(f, lg)      == lg 是 log[f] 的前缀
CanBeElected(c)         == \E Q \in SUBSET ElectionMembers(c) :
                              c \in Q /\ IsMajority(Q, ElectionMembers(c))
                              /\ \A v \in Q : alive[v] /\ VersionLE(meta[v].curr.ver, meta[c].curr.ver)
                           \* election_acceptor.cpp:226 忽略 membership_version 更低的请求
NextMeta(l, sync)       == [prev |-> meta[l].curr,
                            curr |-> [ver |-> <<pid[l], meta[l].curr.ver[2] + 1>>, sync |-> sync],
                            barrier |-> [idx |-> Len(log[l]), pid |-> LastLogPid(log[l])]]
MajorityCaughtUp(l, S)  == IsMajority({f \in S : LogCaughtUp(f, log[l])}, S)
                           \* wait_log_barrier_ / check_follower_sync_status_ / is_accept_quorum_catch_up_
```

`StepDown(v, p)`：如果 `v` 是 F、`role[v] /= Follower`，并且 `pid[v] < p`，就把它置为 `Follower`，同时清空 `cc`、`promises` 和 `pq`。对应 `handle_prepare_request` 里的 `leader_active_to_follower_pending_` 和 `reconfirm_to_follower_pending_`。

`ReceiveMeta(v, m, p)` 表示 v 接收一份由 pid 为 p 的发送方发来的 meta m：
- **条件：**
  - `pid[v] <= p`（`try_update_proposal_id_` 加上 `can_receive_config_log`）
  - `VersionLE(meta[v].curr.ver, m.curr.ver)`
  - `v \in F => PassesBarrier(v, m)`；A 跳过 barrier 检查（假设 2）
- **效果：**
  - `pid[v] := p`，执行 `StepDown(v, p)`，`meta[v] := m`
  - 如果 v 是 F，并且 barrier 后面的下一条日志 pid 小于 **m 自己的 pid**（`m.curr.ver[1]`），就截掉 barrier 之后的所有日志（`pre_check_for_config_log` 的 ghost log 处理）。源码用的是消息 pid p；A 转发旧 meta 时两者不同，会截掉已提交的日志，模型按作者选择的修法改用 meta 的 pid，见 `arbitration/findings.md` 问题 2

## 6. 作者确认的假设（2026-10-04）

1. A 回复 prepare 时，AcceptedPid 是它 meta 里的 pid；A 不会被选为拉日志的来源。
2. A 收到配置 meta 时不做 barrier 检查。
3. learner 也会收到配置 meta。

## 7. 动作

### 选举和 Phase 1（reconfirm，对应 `log_reconfirm.cpp`）

| 动作 | 条件 | 效果 |
|---|---|---|
| `Elect(c, b)` | c 是存活的 F；`role[c]` 为 `Follower` 或 `Prepare`；`c \in meta[c].curr.sync`（proposer 不在列表里就放弃，`election_proposer.cpp:409`）；`CanBeElected(c)`；`pid[c] < b <= MaxPid` | `pid[c] := b`，`role[c] := Prepare`，`promises[c] := {c}`，`pq[c] := [mem ↦ ElectionMembers(c), ver ↦ meta[c].curr.ver]`，`cc[c] := None` |
| `Promise(v, c)` | `role[c] = Prepare`；`v \in pq[c].mem \ {c}`；两者存活；`VersionLE(meta[v].curr.ver, pq[c].ver)`（c 只在持有选举时做 prepare，而投票方不支持配置版本更低的候选，见 `election_acceptor.cpp:226`）；`pid[v] < pid[c]` | `pid[v] := pid[c]`，`StepDown(v, pid[c])`，`promises[c] := promises[c] \cup {v}` |
| `Fetch(c)` | `role[c] = Prepare`；`IsMajority(promises[c], pq[c].mem)`（多数派按 `Elect` 时固定的名单计算，`prepare_quorum_cnt_` 只在 `init_reconfirm_` 里算一次） | 在 `promises[c] \cap F` 中选 `(AcceptedPid, Len)` 最大的 m（A 不参与，假设 1），`log[c] := log[m]`，`role[c] := Reconfirm`，清空 `pq[c]` |

### Phase 2-配置

发起变更都要求 l 存活、`cc[l] = None`、新 seq 不超过 `MaxSeq`，以及 `MajorityCaughtUp(l, 新 sync)`。效果都是 `meta[l] := NextMeta(l, 新 sync)` 和 `cc[l] := [kind, acks |-> {l}]`，也就是 leader 先改写自己的 meta（`append_config_meta_`）。

| 动作 | 额外条件 | 新 sync | 源码 |
|---|---|---|---|
| `StartWorking(l)` | `role[l] = Reconfirm` | 不变 | `confirm_start_working_log` |
| `Degrade(l, s)` | `role[l]` 为 `Reconfirm` 或 `Leader`（`can_do_degrade`）；`s \in meta[l].curr.sync \ {l}`；去掉 s 后同步列表仍不少于一半的 F。s 可以是活着的，用来模拟误判 | 去掉 s | 仲裁服务决定降级一半的 F，但 `degrade_acceptor_to_learner` 对每个成员单独做一次配置变更（`one_stage_config_change_`），所以相邻配置只差一个成员 |
| `Upgrade(l, m)` | `role[l] = Leader`；`m \in F \ meta[l].curr.sync`；m 存活；`log[m] = log[l]` | 加上 m | `upgrade_learner_to_acceptor` |

| 动作 | 条件 | 效果 |
|---|---|---|
| `SendMeta(v, l)` | l 是存活的 F；v 存活，`v /= l`；`ReceiveMeta(v, meta[l], pid[l])` 的条件成立；并且满足以下之一：(a) `cc[l] /= None` 且 `v \notin cc[l].acks`（发送进行中的变更）；(b) `role[l] = Leader`、`cc[l] = None`，且 v 的配置版本更旧（补发当前配置） | 执行 `ReceiveMeta`；情况 (a) 下把 v 加入 `acks`。发送对象包括 learner（假设 3），但只有新列表里的确认才计入多数派 |
| `CommitConfig(l)` | `cc[l] /= None`；`IsMajority(cc[l].acks, ElectionMembers(l))`，这里按新配置计算（`is_reach_majority_`）；如果是 leader 在 `Reconfirm` 中做的 degrade，还要求确认人数达到旧配置（`meta[l].prev`）选举成员的多数派（修正问题 4，见 `arbitration/findings.md`） | `cc[l] := None`；如果 `kind = StartWorking`：`role[l] := Leader`，`commitIdx[l] := barrier.idx`，并把 `log[l]` 中直到 barrier 的条目加入 `committed`（推进到 `saved_end_lsn_`） |
| `ArbPush(f)` | A 和 f 都存活；`CanBeElected(A)`（A 总在 `ElectionMembers(A)` 里）；f 的配置版本比 A 的旧；`ReceiveMeta(f, meta[A], pid[A])` 的条件成立。不要求其他 F 都是 Follower（不建模 lease）；f 若处于 leader 角色且 pid 更小，就退位 | 执行 `ReceiveMeta`（`sync_meta_for_arb_election_leader`） |
| `ArbCatchUpPid(f)` | A 和 f 都存活；`CanBeElected(A)`；f 的配置版本比 A 的旧（A 要向它推送）；`pid[A] < pid[f]`（推送会被拒绝） | `pid[A] := pid[f]`。修正问题 3：接收方拒绝时带回自己的 pid，A 追上后重推。源码里接收方静默拒绝，见 `arbitration/findings.md` 问题 3 |

### Phase 2-日志

| 动作 | 条件 | 效果 |
|---|---|---|
| `Write(l)` | `role[l] = Leader`；`Len(log[l]) < MaxLogLen`。配置变更进行中也可以写 | 追加一条 pid 为 `pid[l]` 的条目 |
| `Replicate(f, l)` | l 是 F，`role[l]` 为 `Reconfirm` 或 `Leader`；`f \in F \ {l}`；两者存活；`pid[f] <= pid[l]`。learner 也能收 | f 的日志是 l 的前缀且更短时，追加下一条；有冲突时，截到第一个冲突位置之前。`pid[f] := pid[l]`，执行 `StepDown` |
| `CommitLog(l, i)` | `role[l] = Leader`；`cc[l] = None`（`is_changing_config_with_arb` 期间冻结）；`commitIdx[l] < i <= Len(log[l])`；`CanCommitUpTo(l, i)` | `commitIdx[l] := i`，把 1..i 的条目加入 `committed` |

`CanCommitUpTo(l, i)` 按 `gen_committed_end_lsn_` 计算。设 `b = meta[l].barrier.idx`，"i 在列表 T 上被多数派确认"指 `IsMajority({f \in T : log[f] 的前 i 条和 log[l] 一致}, T)`：
- 如果 `commitIdx[l] < b`：要求 `i <= b`，并且 i 在 `prev.sync` 或 `curr.sync` 上被多数派确认（源码取两者中较大的位置，再截到 barrier）。
- 否则：i 在 `curr.sync` 上被多数派确认。
- A 永远不计入。

### 故障

- `Crash(s)` 和 `Restart(s)`，见 §4.1。

## 8. 安全性

### 状态不变式

| 名字 | 含义 |
|---|---|
| `TypeOK` | 所有变量类型正确 |
| `LogMatching` | 两个 F 在同一个 LSN 上的条目 pid 相同，那么这个位置之前的日志完全一样 |
| `QuorumIntersection`（I1） | 对任意满足 `c \in meta[c].curr.sync` 的 F c，以及任意满足 `CanBeElected` 条件的 Q（忽略 alive）：Q ∩ F 中 `(AcceptedPid, Len)` 最大的任何一个 F，日志都包含 `committed` 的全部条目 |
| `OneLeaderPerPid`（I2a） | `role` 为 `Reconfirm` 或 `Leader` 的两个不同的 F，pid 不同 |
| `NoDualPrimary`（I2b） | 最多只有一个 F 满足 `AbleToCommit`。`AbleToCommit(l)` 定义为：`role[l] = Leader`，`cc[l] = None`，并且 `meta[l].curr.sync` 中 `pid <= pid[l]` 的 F 达到多数派 |
| `CommittedConsistent`（I3a） | 同一个 LSN 不会以两个不同的 pid 被提交 |
| `LeaderCompleteness`（I3b） | 每个 `role = Leader` 的 l，都包含 `committed` 中所有 `pid <= pid[l]` 的条目 |
| `ArbNotAhead`（I4） | A 的 `curr.sync` 中多数 F 满足以下两条之一：配置版本不低于 A 的；或者 `PassesBarrier(f, meta[A])` 成立 |

### 时序性质（`[][...]_vars`）

- `CommittedMonotonic`：`committed` 只增不减。
- `PidMonotonic`：每个副本的 `pid` 只增不减。
- `ConfigVersionMonotonic`：每个副本的 `meta.curr.ver` 只增不减。

## 9. 活性：从全部正常出发，少数派异常时总能恢复服务

### 要证明的性质

```
StableLeader(l) == alive[l] /\ role[l] = "Leader" /\ cc[l] = None
                   /\ IsMajority({f \in meta[l].curr.sync : alive[f]}, meta[l].curr.sync)

EventuallyStableLeader == <>[](\E l \in F : StableLeader(l))

WritesCommit ==
  \A l \in F, i \in 1..MaxLogLen :
     (alive[l] /\ role[l] = "Leader" /\ Len(log[l]) >= i)
        ~> (commitIdx[l] >= i \/ ~alive[l] \/ role[l] # "Leader")
```

含义：
- `EventuallyStableLeader`：最终总有一个存活的 leader，没有进行中的配置变更，同步列表中的多数派存活，并且一直保持下去。
- `WritesCommit`：leader 写下的每个位置，只要它一直是存活的 leader，最终都会提交。按位置逐个表述，不依赖写入有上限。

（最初的写法 `EventuallyServing` 要求最终"所有写入都已提交"，只在写入有上限时成立，审查后改成上面两条。）

### 活性的前提（环境假设）

活性用同一个模块里的另一组 Next，叫 `LiveNext`。它复用 §7 的动作，只额外加上下面几条**环境**约束。这些约束**从初始状态起一直成立**，所以结论是"从全部正常出发"：不包括先经历一段混乱（多个候选竞争、误判 degrade、副本重启）之后再稳定下来的情况。

| 假设 | 写法 | 理由 |
|---|---|---|
| 异常是少数派，并且不恢复 | `Crash(s)` 只在 `Cardinality(宕机集合 \cup {s}) * 2 < Cardinality(Server)` 时允许；没有 `Restart` | "少数派异常"的定义；从全部正常出发 |
| 选举稳定 | 只有当没有其他存活的 F 处于非 `Follower` 状态时才发起选举；候选只在卡住时重试；`b` 取存活副本 pid 的最大值加 1；卡住且已不可能当选的候选退回 Follower（`LoseElection`，对应续不上选举 lease） | 对应 Paxos 活性所需的"只有一个 proposer" |
| 故障检测准确 | `Degrade` 只降级真正宕机的 F（每次一个）；`Upgrade` 不出现（宕机的副本不会回来） | 对应三步 degrade 中的探测确认 |
| 公平性 | 除 `Write`、`Crash` 外，所有动作都加弱公平 `WF_vars` | 客户端可以停止写入，故障不是必然发生 |

安全性检查不加这些约束：选举可以随时发生、degrade 可以误判、副本可以重启。

"先混乱、后稳定"的情况（在某个时刻之后环境才满足上述约束）留作后续工作。

### 不在活性保证之内的情况（论文需要写明的边界）

如果 degrade 之后，被降级的 F 已经恢复、但还没完成 upgrade（它仍是 learner），这时同步列表里的 F 又发生故障，那么异常的副本虽然只是少数派，系统也无法服务：数据只在那个故障的 F 上，learner 的日志可能不全。这就是原稿说的单副本窗口。活性性质从"全部正常"出发，所以不包括这种情况；见证 `NoLearnerWindow` 证明这个状态确实可达。

## 10. 验证方法

### 文件布局（`arbitration/`）

| 文件 | 内容 |
|---|---|
| `Arbitration.tla` | 模型 |
| `Arbitration.cfg` | 安全性：2F1A，检查 §8 的全部性质，F 对称 |
| `Arbitration4F.cfg` | 安全性：4F1A，边界更小，F 对称 |
| `Liveness.cfg` | 活性：`LiveSpec`，检查 `EventuallyStableLeader` 和 `WritesCommit`。不用对称（TLC 在对称下做活性检查不可靠），边界取更小的值 |
| `Liveness4F.cfg` | 活性：4F1A |
| `Coverage4F.cfg` | 4F1A 的可达性见证 |
| `Coverage.cfg` | 可达性见证，见下文 |
| `LiveCoverage.cfg` | 活性场景见证：一个 F、原 leader、A 分别宕机后仍能恢复服务（用 `BASE=LiveCoverage ./check-witnesses.sh` 运行） |
| `run.sh` | 运行 TLC，使用 `../tools/tla2tools.jar` 和 `/opt/homebrew/opt/openjdk/bin/java`（可用环境变量覆盖） |
| `results.md` | 每个配置的状态数、深度、耗时 |

### 可达性见证（用来确认模型没有写空）

不变式通过，可能只是因为关键路径根本走不到。所以另写一组"见证"：每条都写成某个重要状态"不存在"，TLC **应当找到反例**。找到反例，就证明这条路径可达。

| 见证 | 证明可达的路径 |
|---|---|
| `NoLeader` | reconfirm 能完成 |
| `NoCommittedEntry` | 日志能提交 |
| `NoDegradeCommitted` | degrade 能提交，并且之后还能提交日志 |
| `NoUpgradeAfterDegrade` | 先 degrade 再 upgrade 的完整循环能走通 |
| `NoReconfirmAfterDegrade` | degrade 之后换 leader，reconfirm 能完成 |
| `NoArbPush` | A 推送配置的路径会被触发 |
| `NoGhostTruncate` | leader 发送配置时，ghost log 截断会被触发 |
| `NoArbGhostTruncate` | A 推送配置时，ghost log 截断会被触发（修法 3 改动的路径） |
| `NoArbPushBesideLeader` | 有 F 处于 leader 角色时，A 仍可推送配置（不依赖 lease） |
| `NoHalfSyncCommit` | 同步列表降到一半的 F 之后还能提交日志（4F1A 中需要连续两次 degrade） |
| `NoCommitWithFAndArbDown` | 一个 F 和 A 同时宕机时，不需要 degrade 也能提交（4F1A 中三个 F 仍是多数派） |
| `NoLearnerWindow` | §9 的边界状态可达：唯一的同步 F 宕机，存活的 learner 缺少已提交的日志 |

### 验收标准

1. `Arbitration.cfg`：TLC 不报任何违例，在 `results.md` 里记下状态数、深度、耗时。
2. `Liveness.cfg`（以及 4F1A 的 `Liveness4F.cfg`，如果状态空间允许）：TLC 证明 `EventuallyStableLeader` 和 `WritesCommit` 成立；去掉 `DegradeLive` 或 `CommitLog` 的公平性后，检查应当失败。
3. `Coverage.cfg`：每条见证都找到反例。
4. 如果 `Arbitration.cfg` 或 `Liveness.cfg` 报出违例：先判断是模型写错了，还是协议真的有问题。模型错误就修模型；如果是协议问题，记录反例轨迹，交给作者判断。

### 边界

安全性：2F1A 用默认值（`MaxPid` 3，`MaxLogLen` 2，`MaxSeq` 4）；4F1A 用 `MaxPid` 3，`MaxLogLen` 1，`MaxSeq` 3。活性用更小的边界，例如 `MaxLogLen` 1。
