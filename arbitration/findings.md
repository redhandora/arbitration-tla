# TLC 发现的问题

日期：2026-10-04 至 2026-10-07。模型 `Arbitration.tla`。术语与论文第 5 节一致，名称对照见 [`README.md`](README.md)。

- 问题 1、2 的轨迹：在 2F1A（MaxProposal 3，MaxLogLen 2，MaxConfigSeq 4）下，由当前模型加上 `findings/bug*.diff` 的改动、用单个 worker 生成。
- 问题 3 的轨迹：在 4F1A 的活性检查（`Liveness4F.cfg`）下，由当前模型加上 `findings/bug3.diff` 生成。
- 问题 4 的轨迹：在 4F1A 下生成，详见该节。

源码依据：OceanBase `src/logservice/palf`（GitHub，提交 `0fa1778`）。A 侧的调用方不在开源仓库里，相关判断需要作者结合生产代码确认。

四个问题都已在模型中修正。修正后的检查结果见 `results.md`。

| # | 问题 | 后果 | 需要的故障 | 模型中的处理 |
|---|---|---|---|---|
| 1 | Prepare 阶段不检查配置版本，候选当选后配置被别人改掉，仍能完成日志重确认 | 两个 leader 同时推进提交点（原稿表 37 的 L2） | 两个选举 leader 同时存在 | `Promise` 按配置版本过滤 |
| 2 | A 推送配置时，用自己当前的提案编号作为截断过期日志的阈值 | 已提交日志被截掉，最终丢失 | 一个全量副本崩溃 | 截断阈值改用配置自己的提案编号 |
| 3 | A 的配置领先于存活的全量副本，而它们承诺的提案编号又高于 A；A 的推送被静默拒绝，A 也无从得知对方的提案编号（只在 4F1A 出现） | 一个机房故障后，选举永久卡死（活性） | 一个机房的两个全量副本故障 | 拒绝时带回提案编号，A 追上后重推（`ArbiterAdoptProposal`） |
| 4 | 日志重确认期间的降级建立在新 leader 继承来的、可能未完成的配置上；两任 leader 各做一次单成员降级，能选出 leader 的配置相差两个成员（只在 4F1A 出现） | 已提交日志丢失（安全性） | 一次误判的降级（或副本宕机后恢复）加一次 leader 切换 | 配置确认：降级之前，先以自己的提案编号重新提交继承来的配置（`ConfirmConfig`） |

---

## 问题 1：Prepare 阶段不检查配置版本时出现两个 leader

### 结论

PALF 的 Prepare 阶段（`LogStateMgr::handle_prepare_request`）只比较提案编号，不检查配置版本，日志重确认也不从 Prepare 应答里学习配置。新 leader 用的是自己当选时的配置。

"当选者的配置是最新的"这一点，靠的是选举：投票方忽略 membership_version 更低的请求（`election_acceptor.cpp:226`）。但这个检查只在选举时做。如果候选当选**之后**，另一个 leader 又改了配置，候选仍能用旧配置完成日志重确认，最终两个 leader 都能提交。

### 反例轨迹（16 步，`findings/bug1-dual-primary.trace.txt`）

| 步 | 动作 | 说明 |
|---|---|---|
| 2–3 | f1 当选（提案 1），f2 当选（提案 2） | 两个选举 leader 同时存在。此时各副本配置版本都是 (0,0)，f2 当选合法 |
| 4–8 | f1 完成日志重确认，StartWorking 日志由 {f1, A} 提交 | A 的配置变为 (1,1) |
| 9–10 | f1 降级 f2，A 在提案 1 下确认 | f1 和 A 的配置变为 {f1}，版本 (1,2) |
| 11 | **A 答应 f2 的 Prepare（提案 2）** | A 的配置 (1,2) 比 f2 的 (0,0) 新，但 Prepare 阶段不检查配置版本 |
| 12–14 | f2 用旧配置 {f1, f2} 发起 StartWorking 日志，A 确认 | A 的配置被覆盖为 {f1, f2}，版本 (2,1) |
| 15 | f1 用 A 在第 10 步的确认提交降级 | f1 的日志提交成员组是 {f1}，f1 能提交 |
| 16 | f2 提交 StartWorking 日志，成为 leader | f2 的日志提交成员组是 {f1, f2}，f1 的提案编号不高于 2，f2 也能提交 → `OneActiveLeader` 违例 |

### 真实系统里为什么通常不会发生

真实系统有选举 lease：同一时刻只有一个选举 leader。另外 `is_leader_for_config_change_` 要求配置变更的发起者仍是选举 leader，并且 epoch 没变。所以 f2 当选后，f1 不可能再改配置。反例中第 2–5 步两个选举 leader 并存、第 10–11 步 f1 仍在改配置，在 lease 正常时都不会出现。

所以这不是一个"今天就会触发"的 bug，而是一个**依赖关系**：配置路径的安全性依赖选举（membership_version 过滤和 lease），不像日志路径那样只依赖提案编号。lease 一旦失效（例如时钟漂移超出假设），就可能出现 L2。

### 模型中的处理（作者决定，2026-10-04）

不建模 lease。`Promise(v, c)` 加上 `VersionLE(config[v].curr.version, prepareConfig[c].version)`：投票方只答应配置版本不低于自己的候选。理由是：c 只在持有选举时运行 Prepare 阶段，而投票方不会支持配置版本更低的候选。

### 可选的加固（供作者判断）

让 PALF 的 Prepare 请求带上候选的配置版本，接收方拒绝版本更低的请求。这样配置路径的安全性就不再依赖 lease 的时序，和模型里的写法一致。

### 在模型里复现

应用 `findings/bug1.diff`（删掉 `Promise` 里的版本过滤一行）后运行 `./run.sh Arbitration -workers 1`。TLC 报 `OneActiveLeader` 违例，轨迹同上。

---

## 问题 2：A 推送配置时截掉已提交的日志

### 结论

A 作为选举 leader 推送配置（`sync_meta_for_arb_election_leader` → `pre_sync_config_log_and_mode_meta_`）时，复用了 leader 发配置的 RPC（`submit_change_config_meta_req`）：
- 消息的提案编号是 **A 当前的提案编号**（`state_mgr_->get_proposal_id()`）；
- barrier 是 A 的配置元数据里存的、**更早一任 leader** 的 barrier（`use_propagated_barrier = true`）。

接收方 `receive_config_log` → `pre_check_for_config_log` 无法区分这是不是 A 的同步。barrier 对上之后，如果下一条日志还在 sliding window 里，并且提案编号小于**消息的提案编号**，就当作过期日志截掉。

这条判断的前提是"消息的提案编号和 barrier 来自同一任 leader"：leader 发送时成立，A 转发旧配置时不成立。于是那一任 leader 在 barrier **之后**自己写的、已经提交的日志，也会被截掉。

### 后果

只需要一个全量副本故障，已提交的日志就可能永久丢失。

### 反例轨迹（15 步，`findings/bug2-arbpush-truncate.trace.txt`；已包含问题 1 的修正）

| 步 | 动作 | 说明 |
|---|---|---|
| 2–7 | f1 当选（提案 1），StartWorking 日志由 {f1, A} 提交 | **f2 没收到这份配置**，版本仍是 (0,0)。barrier 在空日志处（index 0） |
| 8–10 | f1 写入 e（提案 1），复制到 f2，由 {f1, f2} 提交 | f2 还不知道 e 已提交（e 仍在 f2 的 sliding window 里） |
| 11–14 | f1 崩溃、重启，用提案 2 发起 Prepare，A 答应 | A 的提案编号变为 2 |
| 15 | **A 推送配置给 f2**：消息的提案编号 2，barrier index 0 | f2 的下一条日志 e 的提案编号 1 < 2，被当作过期日志截掉 |

此时 f2 的配置版本和 A 相同，{f2, A} 可以选出 f2，而 f2 没有 e → `RecoveryComplete` 违例。之后只要 f1 宕机，f2 当选并降级 f1，e 就永久丢失。

这条轨迹里 f1 停在 Prepare 阶段，A 同时是选举 leader（模型不建模 lease）。问题并不依赖两者并存：在实现过程中更早的一版模型里，A 的推送要求所有全量副本都是 Follower，TLC 找到的是 18 步的版本——f1 在第二次 Prepare 之后崩溃，A 是唯一的选举 leader，其余步骤相同。

### 触发条件（真实系统）

1. f2 收到了日志，但没收到上一次 StartWorking 日志的配置（配置消息丢失或延迟），所以 f2 的配置版本比 A 的旧，会接受 A 的推送。
2. f2 收到 A 的推送时，还不知道 e 已提交。如果 e 已经滑出 sliding window，源码不会截断。
3. A 的提案编号已经被一次新的 Prepare 推高到超过 e 的提案编号，而发起这次 Prepare 的候选随后失败或崩溃。
4. A 成为选举 leader，并且向 f2 推送。

### 模型中的处理（作者选择修法 3，2026-10-04）

接收方截断过期日志的阈值改用**配置自己的提案编号**（模型里是 `m.curr.version[1]`），而不是消息的提案编号（`TruncateStaleEntries(f, m)`）。leader 发送自己的配置时两者相等，正常路径不受影响；A 转发旧配置时，只截提案编号小于那一任 leader 的日志，那一任 leader 自己写的日志会保留。

修正后，全部安全性性质通过，可达性见证（包括 `NoStaleTruncate`）仍然全部可达。

### 其他修法（未采用）

1. A 推送时把消息的提案编号换成配置的 `proposal_id_`。风险：如果接收方的提案编号已经更大，`can_receive_config_log` 要求两者相等，接收方会拒收，A 领先导致的选举卡住（问题 3）就可能解不开。
2. 请求里加"仅同步配置"标记，接收方见到就跳过过期日志截断，但保留 barrier 检查。

### 需要作者确认

- 生产环境中 A 侧调用 `sync_meta_for_arb_election_leader` 时，是否另有限制。
- `sync_meta_for_logonly_election_leader` 走同一个函数，logonly 副本当选举 leader 时可能有同样的问题。

### 模型的一处简化

模型不跟踪"follower 已知的提交点"，只要 barrier 对上、下一条的提案编号更小就截断，比源码略宽。源码只截还在 sliding window 里的日志，所以真实系统里需要满足上面的触发条件 2；这一条在真实系统里是可能的（leader 提交后立即崩溃，提交点来不及通知 follower）。

### 在模型里复现

应用 `findings/bug2.diff`（A 推送时的截断阈值改回消息的提案编号，即 `proposal[A]`，和源码一致）后运行 `./run.sh Arbitration -workers 1`。TLC 报 `RecoveryComplete` 违例，轨迹同上。

---

## 问题 3：4F1A 中机房故障后选举永久卡死

### 结论

A 的配置可能领先于所有存活的全量副本（StartWorking 日志只被已故障的全量副本和 A 持久化）。这时全量副本选不上 leader：投票方 A 会忽略 membership_version 更低的候选。PALF 的解法是让 A 作为选举 leader 推送配置（`sync_meta_for_arb_election_leader`）。

但这条通道有个缺口：**如果存活的全量副本已经承诺过一个更大的提案编号**（来自一个随后故障的候选），A 推送配置时带的是自己落后的提案编号，接收方的 `can_receive_config_log` 要求两者相等，于是**静默拒绝**。A 收不到任何应答，也就永远不知道该把提案编号追到多少。

A 的提案编号只会被别人的 Prepare 或更大提案编号的配置消息推高。A 不做日志重确认（`can_be_active_leader()` 只对普通副本为真）；选举模块定期推高的是选举自己的 `ballot_number_`，和 PALF 的 proposal_id 没有联动。所以没有任何动作能打破僵局，直到故障的副本恢复。

### 后果

一个机房故障后，系统可能永久不可写，直到故障的副本恢复。这违反定理 2（少数派异常时可以恢复服务）。2F1A 不受影响：只有第三个全量副本才可能把存活副本的提案编号推高到 A 之上。

### 反例轨迹（14 步，`findings/liveness-4f1a-zone-stall.trace.txt`）

宕机的是 f2、f3 两个全量副本；副本之间是对称的，它们也可以是同一个机房的两个副本。

| 步 | 动作 | 说明 |
|---|---|---|
| 2–5 | f3 当选（提案 1），A、f1 答应，完成 Prepare 阶段 | |
| 6–8 | f3 发起 StartWorking 日志，A、f2 持久化 | A 和 f2、f3 的配置版本变为 (1,1)；f1、f4 仍是 (0,0) |
| 9 | f3 崩溃 | StartWorking 日志还没有提交 |
| 10–12 | f2 当选，用提案 2 发起 Prepare，f1、f4 答应 | **A 没有收到这次 Prepare**，A 的提案编号仍是 1 |
| 13 | f2 崩溃 | 两个全量副本故障，仍是 5 个成员中的少数派 |
| 之后 | 永远没有动作可执行 | f1、f4 的配置版本 (0,0) 低于 A 的 (1,1)，A 不投票；A 推送配置带提案编号 1，f1、f4 承诺的是 2，拒收 |

### 模型中的处理（作者选择，2026-10-04）

`ArbiterAdoptProposal(f)`：A 要向 f 推送配置、但 f 承诺的提案编号比 A 大时，f 在拒绝应答里带回自己的提案编号，A 追到这个值，下一次推送就会被接受。这和 Raft 中节点从应答里追上更大 term 的做法一致。A 提高自己承诺的提案编号只会让它拒绝更多消息，不影响安全性。

**必须和问题 2 的修法一起使用**：A 带着更高的提案编号转发旧配置时，如果仍按消息的提案编号截断，会更容易截掉已提交的日志。

### 其他修法（未采用）

| 修法 | 为什么没选 |
|---|---|
| 接收方只看配置版本、不检查提案编号，接受 A 推送的配置 | 打破"承诺了新提案编号就拒收旧提案编号的配置"这条规则（原稿 P1 修复所依赖的规则），风险大 |
| 配置先发给全量副本，新日志提交成员组中多数全量副本持久化之后才发给 A | 从源头上让 A 不领先，可以作为加固；但每次配置变更多一次到远端 A 的往返，并且改动配置提交的主流程 |
| 投票方拒绝候选时，把更新的配置带给候选 | 跨选举模块和配置管理，还要处理 barrier 检查，改动大 |

### 需要作者确认

- 闭源的 arbserver 一侧是否已有类似机制（例如推送前查询各副本的提案编号）。如果有，模型应改为那个机制。

### 在模型里复现

应用 `findings/bug3.diff`（删掉 `Next`、`LiveNext` 中 A 追提案编号的动作，以及 `Fairness` 中对应的一行），然后运行 `./run.sh Liveness4F`。TLC 在约 31 万个状态、1 分 12 秒时报活性违例，轨迹同上。

---

## 问题 4：4F1A 中，在未确认的配置上降级，Prepare 多数派不再相交

### 结论

单成员变更的安全性依赖一个前提：**每次变更都建立在已经落定的配置上**。这样相邻两个配置的 Prepare 多数派一定相交（引理 1(b)），落定配置的任何 Prepare 多数派里，都有副本持有更新的配置，会拒绝停在更旧配置上的候选（选举时的 membership_version 过滤）。这正是引理 2：仍能选出 leader 的配置两两相邻。

PALF 允许新 leader 在日志重确认期间、StartWorking 日志提交之前就降级（`can_do_degrade`，原稿表 8 的合并）。这时降级的起点是新 leader 继承来的配置，它可能是上一任 leader 没完成的变更。降级的提交只要求**新**配置选举成员组的多数派（`is_reach_majority_` 用的是新配置的 `alive_paxos_replica_num_`）。于是两任 leader 各做一次单成员降级，就可能留下两个都能选出 leader、却相差两个成员的配置，它们的 Prepare 多数派不再相交。

这和 Raft 单成员变更里已知的 bug 是同一类。Raft 的修法是新 leader 先在自己的任期内提交一条 no-op（对应 StartWorking 日志），再允许变更配置。

2F1A 不受影响：降级后日志提交成员组最少一个全量副本，任意两个 Prepare 多数派都相交。

### 后果

已提交的日志丢失：停在旧配置上的副本可以选出一个没有这条日志的 leader，新 leader 再用自己的日志覆盖其他副本。

### 反例轨迹（21 步，`findings/safety-4f1a-uncommitted-base.trace.txt`）

配置记号：C0 = {f1,f2,f3,f4}，C1 = {f1,f3,f4}，C2 = {f1,f3}，选举成员组都要再加上 A。

| 步 | 动作 | 说明 |
|---|---|---|
| 2–6 | f1 当选（提案 1），f3、f4 答应，完成 Prepare 阶段 | f2 也以提案 1 发起了 Prepare，但没有完成 |
| 7–8 | f1 在日志重确认中把 f2 降级，得到 C1；只有 f3 收到 | **C1 只在 f1、f3 上，没有提交**（需要 {f1,f3,f4,A} 中的 3 个） |
| 9–12 | f3 按 C1 当选（提案 2），f1、f4 答应，完成 Prepare 阶段 | f1 的配置版本 (1,1) 不高于 f3 的，可以投票，并因提案编号更小而退位；f4 还停在 C0，也可以投票 |
| 13–15 | f3 在日志重确认中把 f4 降级，得到 C2；f1 确认后提交 | C2 的选举成员组是 {f1,f3,A}，2 个就够，**A 没有参与**；f4 实际还活着（误判） |
| 16–18 | f3 提交 StartWorking 日志，成为 leader | |
| 19–21 | f3 写入 e，复制到 f1，由 {f1,f3} 提交 | |
| 之后 | f2、f4、A 仍停在 C0（版本 (0,0)） | {f2,f4,A} 是 C0 选举成员组 5 个中的 3 个，可以选出 f2，而 f2 没有 e → `RecoveryComplete` 违例 |

C0 和 C2 都能选出 leader（C2 已提交；C0 仍被 f2、f4、A 持有），二者相差两个成员，它们的 Prepare 多数派 {f2,f4,A} 与 {f1,f3} 不相交，违反引理 2。

如果 f4 不是被误判、而是真的宕机后又恢复，结局相同。

### 第一次修法（2026-10-05）及其不足

第一次修法是在提交时检查：leader 还在日志重确认期间做的降级，提交时除了新配置选举成员组的多数派，**还要得到旧配置（`config[l].prev`）选举成员组的多数派**。它挡住了上面这条轨迹，并在 4F1A（MaxProposal 2）上通过了检查。

但它只往回看一步，而且只约束**提交**。一个提出了、却永远提交不了的降级，仍然留在提出者和收到它的副本上，持有它的副本可以用它更小的 Prepare 多数派竞选。用 `Pruned4F`（3 个提案编号）检查第一次修法（`findings/bug4-first-fix.diff`）：

| 检查的性质 | 结果 | 轨迹 |
|---|---|---|
| 全部安全性性质 | `ElectableConfigsAdjacent`（引理 2）违例，11 步，约 4.7 万个状态 | `findings/bug4-first-fix-lemma2.trace.txt` |
| 只检查 `OneLeaderPerProposal` | 违例，20 步，约 2150 万个状态，15 分钟 | `findings/bug4-first-fix-two-leaders.trace.txt` |
| 只检查 `OneActiveLeader`、`Agreement`、`LeaderCompleteness` | 在改名之前的模型上（剪枝方式略不同：无崩溃，MaxConfigSeq 3）：`OneActiveLeader` 违例，27 步，约 1000 万个状态，6 分钟。f1 用 {f1,f4}、f2 用 C0，都以提案 3 提交了 StartWorking 日志，两个 leader 都能推进提交点。后来在新模型上同样的检查跑到深度 24、5500 万个状态仍未结束，没有重跑 | `findings/bug4-first-fix-dual-primary.trace.txt`（旧名称） |

11 步的轨迹：f1（提案 2）和 f2（提案 1）都完成了 Prepare 阶段，各自在没有确认的 C0 上降级一个成员，分别得到 C0 − {f3} 和 C0 − {f1}，都只在提出者自己那里。此时 C0 和这两个配置都能选出 leader，违反引理 2 的"至多两个配置"。这三个配置的 Prepare 多数派恰好仍两两相交（各要 4 个或 5 个成员中的 3 个），所以这一步本身还不造成损害。

20 步的轨迹是两步越界的完整版本：

| 步 | 动作 | 说明 |
|---|---|---|
| 2–7 | f1 当选（提案 1），f3、f4 答应，完成 Prepare 阶段；f2 发起提案 3 的 Prepare，f3 也答应 | |
| 8–9 | f1 在日志重确认中把 f3 降级，得到 {f1,f2,f4}，版本 (1,1)；只有 f4 收到 | 这个降级在本轨迹中没有提交，但留在 f1、f4 上 |
| 10–13 | f4 按 {f1,f2,f4} 当选（提案 2），f1、A 答应，完成 Prepare 阶段 | f1 因提案编号更小而退位 |
| 14–16 | f4 在日志重确认中把 f2 降级，得到 {f1,f4}，版本 (2,2)；A 答应 f2 的提案 3；f1 收到 {f1,f4} | 提交不了：旧配置 {f1,f2,f4,A} 的多数派要 3 个，f2 和 A 都已承诺提案 3。但它留在 f1、f4 上 |
| 17–20 | f1 按 {f1,f4} 发起提案 3 的 Prepare，f4 答应，完成 Prepare 阶段；f2 用 C0 的 {f2,f3,A} 也完成提案 3 的 Prepare 阶段 | {f1,f4} 是 {f1,f4,A} 的多数派。两个副本都以提案 3 完成了 Prepare 阶段 → `OneLeaderPerProposal` 违例 |

C0 和 {f1,f4} 相差两个成员，{f2,f3,A} 与 {f1,f4} 不相交。

### 模型中的处理：配置确认（作者决定，2026-10-06）

`ConfirmConfig(l)`：新 leader 在日志重确认期间降级之前，先以**自己的提案编号**重新提出继承来的配置（成员不变），等它在选举成员组的多数派上提交，但不等日志多数派追平（不同于 StartWorking 日志）。`Degrade` 要求 `ConfigConfirmed(l)`：leader 当前配置的提案编号就是它自己的。已经在任的 leader 通过 StartWorking 日志完成过这一步，不需要再确认。

确认提交之后，继承来的配置已在多数派上以新的提案编号持有。更旧的配置、以及其他 leader 以更小提案编号提出的未完成变更，都和它相邻，Prepare 多数派与它相交，交点的版本更新，会拒绝它们的候选（引理 2）。

- **为什么不先完成 StartWorking 日志再降级：** StartWorking 日志还要等日志多数派追平（`is_accept_quorum_catch_up_`）。2F1A 中另一个全量副本宕机时这一步永远等不到，所以 PALF 才把降级合并进日志重确认。配置确认不等日志，只等配置。
- **代价：** 故障切换时多一轮到选举成员组多数派的往返（2F1A 中是 {幸存的全量副本, A}）。在任 leader 的降级和升级没有额外开销。
- **只在要降级时确认：** 模型里 `ConfirmConfig` 要求存在可以降级的成员。确认的 barrier 在 leader 日志的末尾，A 不检查 barrier，所以 A 可能先于被降级的成员持有确认配置。如果 leader 恰好在降级完成之前宕机，其余副本要等它恢复，和降级刚完成时的单副本窗口相同（见 `NoLearnerWindow`），只是窗口提前了一轮。为此 `ArbiterNotAhead` 放宽为：A 持有的是确认配置时，允许落后的是即将被降级的那一个成员。
- **2F1A：** 任意两个 Prepare 多数派都相交，确认对安全性不是必需的，但规则保持统一。

修正后的检查结果见 `results.md`。

### 需要说明的模型放宽

- 模型允许降级任何一个日志提交成员组成员，只要剩下的不少于一半的全量副本。PALF 的仲裁服务还要求"嫌疑数正好等于一半"，可能会挡住这条轨迹中的某一步，也可能不会：比如 f2 宕机后，f3 看到的嫌疑正好是 f2 和 f4，于是开始逐个降级。
- 反例要求 f4 被误判。真实系统里误判是可能的（例如非对称分区）。

### 需要作者确认

- 闭源部分是否保证：降级之前，leader 当前的配置已经提交。
- 仲裁服务数"嫌疑数"时，已降级的成员算不算在内。

### 在模型里复现

- **原始问题：** 应用 `findings/bug4.diff`（去掉 `Degrade` 中的 `ConfigConfirmed(l)`）后运行 `./run.sh Arbitration4F`。TLC 约 10 秒、11 步报 `ElectableConfigsAdjacent` 违例（`findings/bug4-lemma2.trace.txt`：两个 leader 同时在未确认的 C0 上降级，同第一次修法的 11 步轨迹）。从配置中去掉 `INVARIANT ElectableConfigsAdjacent` 再运行，得到上面这条 21 步的数据丢失轨迹（约 3070 万个状态，28 分钟）。
- **第一次修法：** 应用 `findings/bug4-first-fix.diff` 后运行 `MODULE=Pruned4F ./run.sh Pruned4F`，结果见上表。
