# TLC 发现的问题

日期：2026-10-04 至 2026-10-05。模型 `Arbitration.tla`。问题 1、2 的轨迹在 2F1A（MaxPid 3，MaxLogLen 2，MaxSeq 4）下，由当前模型加上 `findings/bug*.diff` 的改动、用单个 worker 生成；问题 3 的轨迹在 4F1A 的活性检查（`Liveness4F.cfg`）下、由当前模型加上 `findings/bug3.diff` 生成；问题 4 的轨迹在 4F1A 的安全性检查（`Arbitration4F.cfg`）下生成。
源码依据：OceanBase `src/logservice/palf`（GitHub，提交 `0fa1778`）。A 侧的调用方不在开源仓库里，相关判断需要作者结合生产代码确认。

四个问题都已在模型中修正。修正后的检查结果见 `results.md`。

| # | 问题 | 后果 | 需要的故障 | 模型中的处理 |
|---|---|---|---|---|
| 1 | Phase 1 不检查配置版本，候选当选后配置被别人改掉，仍能完成 reconfirm | 双主（原稿表 37 的 L2） | 两个选举 leader 同时存在 | `Promise` 按配置版本过滤 |
| 2 | A 推送配置时，用自己当前的 pid 作为 ghost 裁剪阈值 | 已提交日志被截掉，最终丢失 | 一个 F 崩溃 | 裁剪阈值改用 meta 自己的 pid（修法 3） |
| 3 | A 的配置领先于存活的 F，而存活的 F 的 pid 又高于 A；A 的推送被静默拒绝，A 也无从得知对方的 pid（只在 4F1A 出现） | 一个机房故障后，选举永久卡死（活性） | 一个机房的两个 F 故障 | 拒绝时带回 pid，A 追上后重推（`ArbCatchUpPid`） |
| 4 | 合并进 reconfirm 的 degrade 建立在新 leader 继承来的、可能未提交的配置上；两任 leader 各做一次单成员 degrade，越过最后一个已提交配置两个成员（只在 4F1A 出现） | 已提交日志丢失（安全性） | 一次误判的 degrade（或副本宕机后恢复）加一次 leader 切换 | reconfirm 期间的 degrade 还要得到旧配置的多数派确认 |

---

## 问题 1：Phase 1 不检查配置版本时出现双主

### 结论

PALF 的 prepare（`LogStateMgr::handle_prepare_request`）只比较 proposal_id，不检查配置版本，reconfirm 也不从 prepare 应答里学习配置。新 leader 用的是自己当选时的配置。

"当选者的配置是最新的"这一点，靠的是选举：投票方忽略 membership_version 更低的请求（`election_acceptor.cpp:226`）。但这个检查只在选举时做。如果候选当选**之后**，另一个 leader 又改了配置，候选仍能用旧配置完成 reconfirm，最终两个 leader 都能提交。

### 反例轨迹（16 步，`findings/bug1-dual-primary.trace.txt`）

| 步 | 动作 | 说明 |
|---|---|---|
| 2–3 | f1 当选（pid 1），f2 当选（pid 2） | 两个选举 leader 同时存在。此时各副本配置版本都是 (0,0)，f2 当选合法 |
| 4–8 | f1 reconfirm，START_WORKING 由 {f1, A} 提交 | A 的配置变为 (1,1) |
| 9–10 | f1 degrade f2，A 在 pid 1 下确认 | f1 和 A 的配置变为 {f1}，版本 (1,2) |
| 11 | **A 答应 f2 的 prepare（pid 2）** | A 的配置 (1,2) 比 f2 的 (0,0) 新，但 prepare 不检查配置版本 |
| 12–14 | f2 用旧配置 {f1, f2} 做 START_WORKING，A 确认 | A 的配置被覆盖为 {f1, f2}，版本 (2,1) |
| 15 | f1 用 A 在第 10 步的确认提交 degrade | f1 的同步列表是 {f1}，f1 能提交 |
| 16 | f2 提交 START_WORKING，成为 leader | f2 的同步列表是 {f1, f2}，f1 的 pid 不高于 2，f2 也能提交 → `NoDualPrimary` 违例 |

### 真实系统里为什么通常不会发生

真实系统有选举 lease：同一时刻只有一个选举 leader。另外 `is_leader_for_config_change_` 要求配置变更的发起者仍是选举 leader，并且 epoch 没变。所以 f2 当选后，f1 不可能再改配置。反例中第 2–5 步两个选举 leader 并存、第 10–11 步 f1 仍在改配置，在 lease 正常时都不会出现。

所以这不是一个"今天就会触发"的 bug，而是一个**依赖关系**：配置路径的安全性依赖选举（membership_version 过滤和 lease），不像日志路径那样只依赖 proposal_id。lease 一旦失效（例如时钟漂移超出假设），就可能出现 L2。

### 模型中的处理（作者决定，2026-10-04）

不建模 lease。`Promise(v, c)` 加上 `VersionLE(meta[v].curr.ver, meta[c].curr.ver)`：投票方只答应配置版本不低于自己的候选。理由是：c 只在持有选举时做 prepare，而投票方不会支持配置版本更低的候选。

### 可选的加固（供作者判断）

让 PALF 的 prepare 请求带上候选的配置版本，接收方拒绝版本更低的请求。这样配置路径的安全性就不再依赖 lease 的时序，和模型里的写法一致。

### 在模型里复现

应用 `findings/bug1.diff`（删掉 `Promise` 里的版本过滤一行）后运行 `./run.sh Arbitration`。TLC 报 `QuorumIntersection` 或 `NoDualPrimary` 违例，取决于多个 worker 谁先找到。要得到上面这条双主轨迹，再从 `Arbitration.cfg` 删掉 `INVARIANT QuorumIntersection`，并用 `./run.sh Arbitration -workers 1`。

---

## 问题 2：A 推送配置时截掉已提交的日志

### 结论

A 作为选举 leader 推送配置（`sync_meta_for_arb_election_leader` → `pre_sync_config_log_and_mode_meta_`）时，复用了 leader 发配置的 RPC（`submit_change_config_meta_req`）：
- 消息 pid 是 **A 当前的 pid**（`state_mgr_->get_proposal_id()`）；
- barrier 是 A 的 meta 里存的、**更早一任 leader** 的 barrier（`use_propagated_barrier = true`）。

接收方 `receive_config_log` → `pre_check_for_config_log` 无法区分这是不是 A 的同步。barrier 对上之后，如果下一条日志还在 sliding window 里，并且 pid 小于**消息 pid**，就当作 ghost 截掉。

这条 ghost 判断的前提是"消息 pid 和 barrier 来自同一任 leader"：leader 发送时成立，A 转发旧 meta 时不成立。于是那一任 leader 在 barrier **之后**自己写的、已经提交的日志，也会被截掉。

### 后果

只需要一个 F 故障，已提交的日志就可能永久丢失。

### 反例轨迹（15 步，`findings/bug2-arbpush-truncate.trace.txt`；已包含问题 1 的修正）

| 步 | 动作 | 说明 |
|---|---|---|
| 2–7 | f1 当选（pid 1），START_WORKING 由 {f1, A} 提交 | **f2 没收到这份配置**，版本仍是 (0,0)。barrier 在空日志处（idx 0） |
| 8–10 | f1 写入 e（pid 1），复制到 f2，由 {f1, f2} 提交 | f2 还不知道 e 已提交（e 仍在 f2 的 sliding window 里） |
| 11–14 | f1 崩溃、重启，用 pid 2 发起 prepare，A 答应 | A 的 pid 变为 2 |
| 15 | **A 推送配置给 f2**：消息 pid 2，barrier idx 0 | f2 的下一条日志 e 的 pid 1 < 2，被当作 ghost 截掉 |

此时 f2 的配置版本和 A 相同，{f2, A} 可以选出 f2，而 f2 没有 e → `QuorumIntersection` 违例。之后只要 f1 宕机，f2 当选并 degrade f1，e 就永久丢失。

这条轨迹里 f1 停在 Prepare，A 同时是选举 leader（模型不建模 lease）。问题并不依赖两者并存：在实现过程中更早的一版模型里，`ArbPush` 要求所有 F 都是 Follower，TLC 找到的是 18 步的版本——f1 在第二次 prepare 之后崩溃，A 是唯一的选举 leader，其余步骤相同。

### 触发条件（真实系统）

1. f2 收到了日志，但没收到上一次 START_WORKING 的配置（配置消息丢失或延迟），所以 f2 的配置版本比 A 的旧，会接受 A 的推送。
2. f2 收到 A 的推送时，还不知道 e 已提交。如果 e 已经滑出 sliding window，源码不会截断。
3. A 的 pid 已经被一次新的 prepare 推高到超过 e 的 pid，而发起这次 prepare 的候选随后失败或崩溃。
4. A 成为选举 leader，并且向 f2 推送。

### 模型中的处理（作者选择修法 3，2026-10-04）

接收方的 ghost 裁剪阈值改用 **meta 自己的 proposal_id**（模型里是 `m.curr.ver[1]`），而不是消息 pid（`LogAfterMeta(f, m)`）。leader 发送自己的配置时两者相等，正常路径不受影响；A 转发旧 meta 时，只截 pid 小于那一任 leader 的日志，那一任 leader 自己写的日志会保留。

修正后，全部安全性性质通过，9 条可达性见证（包括 `NoGhostTruncate`）仍然全部可达。

### 其他修法（未采用）

1. A 推送时把消息 pid 换成 meta 的 `proposal_id_`。风险：如果接收方的 pid 已经更大，`can_receive_config_log` 要求两者相等，接收方会拒收，A 领先导致的选举卡住（P2）就可能解不开。
2. 请求里加"仅同步配置"标记，接收方见到就跳过 ghost 裁剪，但保留 barrier 检查。

### 需要作者确认

- 生产环境中 A 侧调用 `sync_meta_for_arb_election_leader` 时，是否另有限制。
- `sync_meta_for_logonly_election_leader` 走同一个函数，logonly 副本当选举 leader 时可能有同样的问题。

### 模型的一处简化

模型不跟踪"follower 已知的提交点"，只要 barrier 对上、下一条 pid 更小就截断，比源码略宽。源码只截还在 sliding window 里的日志，所以真实系统里需要满足上面的触发条件 2；这一条在真实系统里是可能的（leader 提交后立即崩溃，提交点来不及通知 follower）。

### 在模型里复现

应用 `findings/bug2.diff`（`ArbPush` 的裁剪阈值改回消息 pid，即 `pid[A]`，和源码一致）后运行 `./run.sh Arbitration -workers 1`。TLC 报 `QuorumIntersection` 违例，轨迹同上。

---

## 问题 3：4F1A 中机房故障后选举永久卡死

### 结论

A 的配置可能领先于所有存活的 F（START_WORKING 只被已故障的 F 和 A 持久化）。这时 F 选不上 leader：投票方 A 会忽略 membership_version 更低的候选。PALF 的解法是让 A 作为选举 leader 推送配置（`sync_meta_for_arb_election_leader`）。

但这条通道有个缺口：**如果存活的 F 已经答应过一个更大的 pid**（来自一个随后故障的候选），A 推送配置时带的是自己落后的 pid，F 的 `can_receive_config_log` 要求两者相等，于是**静默拒绝**。A 收不到任何应答，也就永远不知道该把 pid 追到多少。

A 的 pid 只会被别人的 prepare 或更大 pid 的配置消息推高。A 不做 reconfirm（`can_be_active_leader()` 只对普通副本为真）；选举模块定期推高的是选举自己的 `ballot_number_`，和 PALF 的 proposal_id 没有联动。所以没有任何动作能打破僵局，直到故障的 F 恢复。

### 后果

一个机房故障后，系统可能永久不可写，直到故障的副本恢复。这违反"少数派异常时可以恢复服务"的活性。2F1A 不受影响：只有第三个 F 才可能把存活副本的 pid 推高到 A 之上。

### 反例轨迹（17 步，`findings/liveness-4f1a-zone-stall.trace.txt`）

宕机的 f1、f2 正好是同一个机房的两个 F。

| 步 | 动作 | 说明 |
|---|---|---|
| 2–5 | f1 当选（pid 1），f2、A 答应，完成 Phase 1 | |
| 6–9 | f1 的 START_WORKING 由 f1、f2、A 持久化并提交，f1 成为 leader | A 和 f1、f2 的配置版本变为 (1,1)；另一机房的 f3、f4 仍是 (0,0) |
| 10–11 | f1 写入一条日志，随后崩溃 | |
| 12–15 | f2 当选，用 pid 2 发起 prepare，f3、f4 答应，完成 Phase 1 | **A 没有收到这次 prepare**，A 的 pid 仍是 1 |
| 16–17 | f2 发起 START_WORKING 后崩溃 | 机房 {f1, f2} 整体故障 |
| 之后 | 永远没有动作可执行 | f3、f4 的配置版本 (0,0) 低于 A 的 (1,1)，A 不投票；A 推送配置带 pid 1，f3、f4 的 pid 是 2，拒收 |

### 模型中的处理（作者选择，2026-10-04）

`ArbCatchUpPid(f)`：A 要向 f 推送配置、但 f 的 pid 比 A 大时，f 在拒绝应答里带回自己的 pid，A 把 pid 追到这个值，下一次推送就会被接受。这和 Raft 中节点从应答里追上更大 term 的做法一致。A 提高自己承诺的 pid 只会让它拒绝更多消息，不影响安全性。

**必须和问题 2 的修法 3 一起使用**：A 带着更高的 pid 转发旧配置时，如果仍按消息 pid 裁剪，会更容易截掉已提交的日志。

### 其他修法（未采用）

| 修法 | 为什么没选 |
|---|---|
| 接收方只看配置版本、不检查 pid，接受 A 推送的配置 | 打破"答应了新 pid 就拒收旧 pid 的配置"这条规则（原稿 P1 修复所依赖的规则），风险大 |
| 配置先发给 F，新同步列表中多数 F 持久化之后才发给 A | 从源头上让 A 不领先，可以作为加固；但每次配置变更多一次到远端 A 的往返，并且改动配置提交的主流程 |
| 投票方拒绝候选时，把更新的配置带给候选 | 跨选举模块和配置管理，还要处理 barrier 检查，改动大 |

### 需要作者确认

- 闭源的 arbserver 一侧是否已有类似机制（例如推送前查询各副本的 pid）。如果有，模型应改为那个机制。

### 在模型里复现

应用 `findings/bug3.diff`（删掉 `Next`、`LiveNext` 中的 A 追 pid 动作，以及 `Fairness` 中对应的一行），然后运行 `./run.sh Liveness4F`。TLC 在约 35 万个状态、1 分钟左右报活性违例，轨迹同上。

---

## 问题 4：4F1A 中，在未提交的配置上再做 degrade，多数派不再相交

### 结论

单成员变更的安全性依赖一个前提：**每次变更都建立在已提交的配置上**。这样相邻两个配置的多数派一定相交，最后一个已提交配置的任何多数派里，都有副本持有更新的配置，会拒绝停在旧配置上的候选（选举时的 membership_version 过滤）。

PALF 允许新 leader 在 reconfirm 期间、START_WORKING 提交之前就做 degrade（`can_do_degrade`，原稿表 8 的合并）。这时 degrade 的起点是新 leader 继承来的配置，它可能是上一任 leader 没提交完的变更。degrade 的提交只要求**新**配置选举成员的多数派（`is_reach_majority_` 用的是新配置的 `alive_paxos_replica_num_`）。于是两任 leader 各做一次单成员 degrade，就可能越过最后一个已提交的配置两个成员，两边的多数派不再相交。

这和 Raft 单成员变更里已知的 bug 是同一类。Raft 的修法是新 leader 先在自己的任期内提交一条 no-op（对应 START_WORKING），再允许变更配置。

2F1A 不受影响：降级后同步列表最少一个 F，配置最多只差一个成员；而且新旧两份配置的多数派都是 {幸存的 F, A}。

### 后果

已提交的日志丢失：停在旧配置上的副本可以选出一个没有这条日志的 leader，新 leader 再用自己的日志覆盖其他副本。

### 反例轨迹（20 步，`findings/safety-4f1a-uncommitted-base.trace.txt`）

配置记号：C0 = {f1,f2,f3,f4}，C1 = {f1,f3,f4}，C2 = {f1,f4}，选举成员都要再加上 A。

| 步 | 动作 | 说明 |
|---|---|---|
| 2–5 | f1 当选（pid 1），f1、f2、f3 答应，完成 Phase 1 | |
| 6–7 | f1 在 reconfirm 中把 f2 降级，得到 C1；只有 f4 确认 | **C1 只在 f1、f4 上，没有提交**（需要 {f1,f3,f4,A} 中的 3 个） |
| 8–11 | f4 按 C1 当选（pid 2），f1、f3 答应，完成 Phase 1 | f3 的配置 C0 版本更低，可以投票；f1 因 pid 更小而退位 |
| 12–14 | f4 在 reconfirm 中把 f3 降级，得到 C2；f1 确认后提交 | C2 的选举成员是 {f1,f4,A}，2 个就够，**A 没有参与**；f3 实际还活着（误判） |
| 15–17 | f4 完成 START_WORKING，成为 leader | |
| 18–20 | f4 写入 e，复制到 f1，由 {f1,f4} 提交 | |
| 之后 | f2、f3、A 仍停在 C0（版本 (0,0)） | {f2,f3,A} 是 C0 选举成员 5 个中的 3 个，可以选出 f2，而 f2 没有 e → `QuorumIntersection` 违例 |

如果 f3 不是被误判、而是真的宕机后又恢复，结局相同。

### 模型中的处理（作者选择，2026-10-05）

leader 还在 reconfirm 时做的 degrade，提交时除了新配置选举成员的多数派，**还要得到旧配置（`meta[l].prev`）选举成员的多数派**。旧配置的多数派确认了新配置，就等于旧配置已在多数派上落定，而且这些副本的版本都更高了，之后停在更早配置上的候选凑出的多数派里一定有它们，会被拒绝。

这个修法和"f3 降级之前，先让前一个配置变更在多数派上完成"是同一个原则，只是把两步合成一轮：

- **为什么不先完成 START_WORKING 再 degrade：** START_WORKING 还要等日志多数派追平（`is_accept_quorum_catch_up_`）。2F1A 中另一个 F 宕机时这一步永远等不到，所以 PALF 才把 degrade 合并进 reconfirm。
- **2F1A 没有额外开销：** 新旧两份配置的多数派都是 {幸存的 F, A}，同一批确认就够，不多等一次到远端 A 的往返。
- **机房故障后仍能恢复：** 4F1A 中两次降级各自都能凑齐新旧两边的多数派（例如 f3、f4、A）。
- **只在 reconfirm 期间生效：** START_WORKING 提交之后，leader 的配置已在自己的 pid 下提交过，后续 degrade 和 upgrade 照常只要求新配置的多数派。

修正后的检查结果见 `results.md`。

### 需要说明的模型放宽

- 模型允许 degrade 任何一个同步列表成员，只要剩下的不少于一半的 F。PALF 的仲裁服务还要求"嫌疑数正好等于一半"，可能会挡住这条轨迹中的某一步，也可能不会：比如 f1 宕机后，f4 看到的嫌疑正好是 f1 和 f3，于是开始逐个降级。
- 第 12 步要求 f3 被误判。真实系统里误判是可能的（例如非对称分区）。

### 需要作者确认

- 闭源部分是否保证：degrade 之前，leader 当前的配置已经提交。
- 仲裁服务数"嫌疑数"时，已降级的成员算不算在内。

### 在模型里复现

应用 `findings/bug4.diff`（删掉 `CommitConfig` 中 reconfirm 期间 degrade 要求旧配置多数派的条件），然后运行 `./run.sh Arbitration4F`。TLC 报 `QuorumIntersection` 违例（本次在约 1900 万个状态、深度 21、15 分钟时报出）。

