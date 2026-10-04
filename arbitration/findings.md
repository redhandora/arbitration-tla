# TLC 发现的问题

日期：2026-10-04。模型 `Arbitration.tla`，2F1A，MaxPid 3，MaxLogLen 2，MaxSeq 4。
源码依据：OceanBase `src/logservice/palf`（GitHub，提交 `0fa1778`）。A 侧的调用方不在开源仓库里，相关判断需要作者结合生产代码确认。

两个问题都已在模型中修正。修正后，全部安全性性质通过，见 `results.md`。

| # | 问题 | 后果 | 需要的故障 | 模型中的处理 |
|---|---|---|---|---|
| 1 | Phase 1 不检查配置版本，候选当选后配置被别人改掉，仍能完成 reconfirm | 双主（原稿表 37 的 L2） | 两个选举 leader 同时存在 | `Promise` 按配置版本过滤 |
| 2 | A 推送配置时，用自己当前的 pid 作为 ghost 裁剪阈值 | 已提交日志被截掉，最终丢失 | 一个 F 崩溃 | 裁剪阈值改用 meta 自己的 pid（修法 3） |

---

## 问题 1：Phase 1 不检查配置版本时出现双主

### 结论

PALF 的 prepare（`LogStateMgr::handle_prepare_request`）只比较 proposal_id，不检查配置版本，reconfirm 也不从 prepare 应答里学习配置。新 leader 用的是自己当选时的配置。

"当选者的配置是最新的"这一点，靠的是选举：投票方忽略 membership_version 更低的请求（`election_acceptor.cpp:226`）。但这个检查只在选举时做。如果候选当选**之后**，另一个 leader 又改了配置，候选仍能用旧配置完成 reconfirm，最终两个 leader 都能提交。

### 反例轨迹（17 步，`findings/bug1-dual-primary.trace.txt`）

| 步 | 动作 | 说明 |
|---|---|---|
| 2–5 | f1 当选（pid 1），f2 当选（pid 2） | 两个选举 leader 同时存在。此时各副本配置版本都是 (0,0)，f2 当选合法 |
| 6–9 | f1 reconfirm，START_WORKING 由 {f1, A} 提交 | A 的配置变为 (1,1) |
| 10–11 | f1 degrade f2，A 在 pid 1 下确认 | f1 和 A 的配置变为 {f1}，版本 (1,2) |
| 12 | **A 答应 f2 的 prepare（pid 2）** | A 的配置 (1,2) 比 f2 的 (0,0) 新，但 prepare 不检查配置版本 |
| 13–15 | f2 用旧配置 {f1, f2} 做 START_WORKING，A 确认 | A 的配置被覆盖为 {f1, f2}，版本 (2,1) |
| 16 | f2 提交 START_WORKING，成为 leader | f2 的同步列表是 {f1, f2}，f1 的 pid 不高于 2，f2 能提交 |
| 17 | f1 用 A 在第 11 步的确认提交 degrade | f1 的同步列表是 {f1}，f1 也能提交 → `NoDualPrimary` 违例 |

### 真实系统里为什么通常不会发生

真实系统有选举 lease：同一时刻只有一个选举 leader。另外 `is_leader_for_config_change_` 要求配置变更的发起者仍是选举 leader，并且 epoch 没变。所以 f2 当选后，f1 不可能再改配置。反例中第 2–5 步两个选举 leader 并存、第 10–11 步 f1 仍在改配置，在 lease 正常时都不会出现。

所以这不是一个"今天就会触发"的 bug，而是一个**依赖关系**：配置路径的安全性依赖选举（membership_version 过滤和 lease），不像日志路径那样只依赖 proposal_id。lease 一旦失效（例如时钟漂移超出假设），就可能出现 L2。

### 模型中的处理（作者决定，2026-10-04）

不建模 lease。`Promise(v, c)` 加上 `VersionLE(meta[v].curr.ver, meta[c].curr.ver)`：投票方只答应配置版本不低于自己的候选。理由是：c 只在持有选举时做 prepare，而投票方不会支持配置版本更低的候选。

### 可选的加固（供作者判断）

让 PALF 的 prepare 请求带上候选的配置版本，接收方拒绝版本更低的请求。这样配置路径的安全性就不再依赖 lease 的时序，和模型里的写法一致。

### 在模型里复现

删掉 `Promise` 里的 `VersionLE(...)` 一行。TLC 会先报 `QuorumIntersection` 违例；再从 `Arbitration.cfg` 里去掉这条不变式，就会报上面的 `NoDualPrimary` 违例。

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

### 反例轨迹（18 步，`findings/bug2-arbpush-truncate.trace.txt`；已包含问题 1 的修正）

| 步 | 动作 | 说明 |
|---|---|---|
| 2–9 | f1 当选（pid 2），START_WORKING 由 {f1, A} 提交 | **f2 没收到这份配置**，版本仍是 (0,0)。barrier 在空日志处（idx 0） |
| 10–12 | f1 写入 e（pid 2），复制到 f2，由 {f1, f2} 提交 | f2 还不知道 e 已提交（e 仍在 f2 的 sliding window 里） |
| 13–16 | f1 崩溃、重启，用 pid 3 发起 prepare，A 答应 | A 的 pid 变为 3 |
| 17 | f1 再次崩溃 | 全程只有 f1 故障 |
| 18 | **A 推送配置给 f2**：消息 pid 3，barrier idx 0 | f2 的下一条日志 e 的 pid 2 < 3，被当作 ghost 截掉 |

此时 f2 的配置版本和 A 相同，{f2, A} 可以选出 f2，而 f2 没有 e → `QuorumIntersection` 违例。继续执行下去，f2 当选、degrade 已宕机的 f1，e 就永久丢失了。

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

把 `LogAfterMeta` 的阈值改回发送方的 pid，也就是在 `ArbPush` 里用 `pid[A]` 作为阈值。TLC 会报 `QuorumIntersection` 违例，轨迹同上。
