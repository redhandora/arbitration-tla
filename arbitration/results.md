# TLC 结果

日期：2026-10-05。TLC 2.14（`tools/tla2tools.jar`），OpenJDK 27，8 个 worker。规格 `Arbitration.tla`，共 772 行。

**前提：** 下面的结果针对"PALF 源码 + 四处修正"的协议，四处修正见 [`findings.md`](findings.md)：

| 问题 | 模型中的修正 |
|---|---|
| 1 | Phase 1 收 promise 时按候选发起选举时的配置版本过滤 |
| 2 | ghost 日志裁剪阈值用配置自己的 pid |
| 3 | 接收方拒绝 A 的推送时带回 pid，A 追上后重推 |
| 4 | reconfirm 期间的 degrade 还要得到旧配置多数派的确认 |

模型不建模选举 lease，允许多个选举 leader 同时存在。问题 1 的版本过滤是对"选举时投票方忽略 membership_version 更低的请求"的抽象。

所有检查都基于同一份 `Spec` / `LiveSpec`。见证的定义不影响这两个规格的状态空间。

## 安全性

| 配置 | 部署 | MaxPid | MaxLogLen | MaxSeq | 不同状态 | 生成状态 | 深度 | 耗时 | 结果 |
|---|---|---|---|---|---|---|---|---|---|
| `Arbitration.cfg` | 2F1A | 3 | 2 | 4 | 3,133,352 | 12,866,822 | 42 | 38 秒 | 通过 |
| `ArbitrationBigPid.cfg` | 2F1A | 4 | 2 | 4 | 14,611,700 | 60,295,156 | 47 | 2 分 49 秒 | 通过 |
| `ArbitrationBigLog.cfg` | 2F1A | 3 | 3 | 5 | 15,863,088 | 66,284,745 | 47 | 2 分 44 秒 | 通过 |
| `Arbitration4F.cfg` | 4F1A | 2 | 1 | 3 | 364,559,468 | 2,884,378,278 | 40 | 5 小时 56 分 | 通过 |

都开了 F 的对称性。

检查的性质：

| 性质 | 含义 |
|---|---|
| TypeOK | 类型正确 |
| LogMatching | 同一 LSN 上 pid 相同的两条日志，之前的日志完全一样 |
| QuorumIntersection（I1） | 任何能完成 Phase 1 的 F，恢复出的日志都包含全部已提交条目 |
| OneLeaderPerPid（I2a） | 每个 pid 最多一个 leader |
| NoDualPrimary（I2b） | 任一时刻最多一个 leader 能推进提交点 |
| CommittedConsistent（I3a） | 同一 LSN 不会以两个不同的 pid 被提交 |
| LeaderCompleteness（I3b） | leader 包含所有 pid 不高于自己的已提交条目 |
| ArbNotAhead（I4） | A 的配置不会领先到其同步列表的多数 F 追不上 |
| CommittedMonotonic | 已提交集合只增不减 |
| PidMonotonic | 每个副本的 pid 只增不减 |
| ConfigVersionMonotonic | 每个副本的配置版本只增不减 |

## 活性

| 配置 | 部署 | MaxPid | MaxLogLen | MaxSeq | 不同状态 | 深度 | 耗时 | 结果 |
|---|---|---|---|---|---|---|---|---|
| `Liveness.cfg` | 2F1A | 3 | 1 | 4 | 1,028 | 20 | 5 秒 | 通过 |
| `Liveness4F.cfg` | 4F1A | 5 | 1 | 5 | 3,095,190 | 41 | 12 分 16 秒 | 通过 |

不用对称性（TLC 在对称下做活性检查不可靠）。

检查的性质：
- `EventuallyStableLeader == <>[](\E l \in F : StableLeader(l))`：最终总有一个存活的 leader，没有进行中的配置变更，同步列表中的多数派存活，并且一直保持。
- `WritesCommit`：leader 写下的每个位置，只要它一直是存活的 leader，最终都会提交。按位置逐个表述，不依赖写入有上限。

前提（只用于活性，安全性检查不加），从初始状态起一直成立：
- 异常是少数派，且不恢复；
- 选举稳定：有存活的非 Follower F 时，其他 F 不发起选举，A 也不作为选举 leader 推送配置；卡住且已不可能当选的候选退回 Follower；
- 故障检测准确：只 degrade 真正宕机的 F；
- 除写入和崩溃外，所有动作弱公平。

所以结论是"从全部正常出发，少数派异常时最终恢复服务"。"先混乱、后稳定"的情况没有覆盖。

**边界的依据：** 活性模型最多坏 2 个副本（4F1A，5 个中的少数派），最多换 2 次 leader，一共 3 个 leader：
- 配置 seq 最多 5 个：3 次 START_WORKING，加 2 次 degrade；
- pid 最多 5 个：3 次选举，加 2 次重试。

2F1A 最多坏 1 个副本，相应需要 seq ≤ 3、pid ≤ 3。

**非空洞性（去掉某个机制后检查应当失败）：**

| 改动 | 部署 | 结果 |
|---|---|---|
| 不带公平性的 `Spec` | 2F1A | 违例（系统可以一直不动） |
| 去掉 `DegradeLive` 的弱公平 | 2F1A | 违例 |
| 去掉 `CommitLog` 的弱公平 | 2F1A | 违例 |
| 去掉 A 追 pid（`findings/bug3.diff`，问题 3） | 4F1A | 违例：一个机房故障后选举卡死，约 35 万个状态，1 分 13 秒 |

## 可达性见证

每条见证写成"某状态不存在"，TLC 找到反例即代表该路径可达。8 个 worker 并行时，轨迹不一定最短。

| 见证 | 证明可达的路径 | 2F1A 步数 | 4F1A 步数 |
|---|---|---|---|
| NoReconfirm | Phase 1 能完成拉日志 | 4 | — |
| NoLeader | reconfirm 能完成 | 7 | 11 |
| NoArbPush | A 推送配置会被触发 | 6 | 8 |
| NoArbPushBesideLeader | 有 F 处于 leader 角色时 A 仍可推送（不依赖 lease） | 6 | 8 |
| NoArbCatchUp | A 追上更大的 pid（问题 3 的修正） | 7 | 8 |
| NoCommittedEntry | 日志能提交 | 10 | 14 |
| NoDegradeCommitted | degrade 提交后还能提交日志 | 12 | 17 |
| NoHalfSyncCommit | 同步列表降到一半的 F 后还能提交（4F1A 需要两次 degrade） | — | 20 |
| NoCommitWithFAndArbDown | 一个 F 和 A 同时宕机，不 degrade 也能提交（只在 4F1A 可达） | — | 16 |
| NoUpgradeAfterDegrade | learner 追上已提交日志后被 upgrade | 16 | 21 |
| NoReconfirmAfterDegrade | degrade 后换 pid 重新 reconfirm，恢复已提交日志 | 15 | 19 |
| NoGhostTruncate | leader 发配置时 ghost 日志截断会被触发 | 12 | 16 |
| NoArbGhostTruncate | A 推送配置时 ghost 日志截断会被触发（问题 2 修正的路径） | 13 | 16 |
| NoLearnerWindow | 单副本窗口：同步列表的 F 全部宕机，存活的 learner 缺少已提交日志 | 13 | 17 |

2F1A 用 `Coverage.cfg`（边界同 `Arbitration.cfg`，不用对称），4F1A 用 `Coverage4F.cfg`（边界同 `Arbitration4F.cfg`，用对称）。"—"表示没有在该部署上运行，或者该部署下不可达。

活性场景（`LiveCoverage.cfg`，2F1A，边界同 `Liveness.cfg`）：

| 见证 | 证明发生的场景 | 步数 |
|---|---|---|
| NoServingAfterFCrash | 一个 F 宕机后，幸存者 degrade 它并继续服务 | 11 |
| NoServingAfterLeaderCrash | 原 leader 宕机后，新 leader 恢复其日志并服务 | 20 |
| NoServingAfterArbCrash | A 宕机后继续服务 | 8 |

## 发现的问题：修正前后

| 问题 | 修正前（应用 `findings/bugN.diff`） | 修正后 |
|---|---|---|
| 1 双主 | 2F1A：`NoDualPrimary` 违例，16 步 | 通过 |
| 2 A 推送截掉已提交日志 | 2F1A：`QuorumIntersection` 违例，15 步 | 通过 |
| 3 机房故障后选举卡死 | 4F1A 活性：违例，17 步 | 通过 |
| 4 在未提交配置上再 degrade | 4F1A：`QuorumIntersection` 违例，约 1900 万个状态、深度 21、15 分钟 | 通过 |

## 复现

```bash
cd arbitration
./run.sh Arbitration              # 2F1A 安全性
./run.sh ArbitrationBigPid        # 2F1A，MaxPid 4
./run.sh ArbitrationBigLog        # 2F1A，MaxLogLen 3，MaxSeq 5
./run.sh Arbitration4F            # 4F1A 安全性（约 6 小时，约 14 GB 磁盘）
./run.sh Liveness                 # 2F1A 活性
./run.sh Liveness4F               # 4F1A 活性（约 12 分钟）
./check-witnesses.sh              # 2F1A 见证，每条都应输出 REACHED
BASE=Coverage4F ./check-witnesses.sh NoLeader NoHalfSyncCommit NoCommitWithFAndArbDown ...
BASE=LiveCoverage ./check-witnesses.sh NoServingAfterFCrash \
  NoServingAfterLeaderCrash NoServingAfterArbCrash
```

`run.sh` 默认使用 12 GB 堆。两个大检查（4F1A 安全性、4F1A 活性）不要同时运行。

## 模型修改记录（实现和审查过程中）

| 修改 | 原因 |
|---|---|
| `Promise` 增加配置版本过滤 | 问题 1，作者决定 |
| ghost 裁剪阈值改用配置自己的 pid | 问题 2，作者选择修法 3 |
| 新增 `ArbCatchUpPid` | 问题 3，作者选择修法 A |
| reconfirm 期间的 degrade 需要旧配置多数派 | 问题 4，作者决定 |
| prepare 名单和配置版本在 `Elect` 时快照（`pq`） | 审查发现：PALF 在 `init_reconfirm_` 固定 prepare 名单；版本过滤也用发起选举时的版本，否则 4F1A 中候选在 prepare 中途接受别人的配置后，会凑出不相交的多数派 |
| degrade 每次只降一个成员 | 审查发现：`degrade_acceptor_to_learner` 对每个成员单独做配置变更 |
| `ArbPush` 不再要求所有 F 都是 Follower，改为接收方按 pid 退位 | 审查发现：原条件隐含了 lease 假设 |
| 活性性质拆成 `EventuallyStableLeader` 和 `WritesCommit` | 审查发现：原性质只在写入有上限时成立 |
| 活性模型新增 `LoseElection`，并要求 A 只在没有 F 持有选举时推送 | 让候选和 A 遵守同一条"选举稳定"前提 |
| `PassesBarrier` 用 IF 而不是 `\/` | TLC 在 action 里会求值 `\/` 的每个分支，原写法越界 |
| `NoLearnerWindow` 改为"同步列表的 F 全部宕机" | 原定义"只剩一个同步 F"在 4F1A 不可达 |
| `run.sh` 不再用 `-cleanup` | 它会清掉整个 `states/` 目录，误杀并行的检查 |

## 已知的模型简化

- **不建模选举 lease。** 允许多个选举 leader 同时存在；配置路径的安全性依靠 `Promise` 的配置版本过滤。
- **共享状态模型。** 一个副本直接读另一个副本的当前状态，覆盖不到迟到或重复的旧消息。
- **不跟踪 follower 已知的提交点。** ghost 裁剪比源码略宽（源码只截还在 sliding window 里的日志）。
- **leader 直接读副本的日志内容。** `MajorityCaughtUp` 和 `AckedBy` 直接看副本的日志，包括已宕机副本持久化的日志，相当于 leader 总能知道副本已有哪些日志。这一方面多出了行为（leader 不需要等宕机副本回应），另一方面也少了行为：源码中 `match_lsn_map_` 的确认可能已经过时（副本之后被截断），模型里没有这种过时确认。审查者在 2F1A 中用带 `match_lsn_map_` 的变体验证过，结果相同；4F1A 没有用这个变体验证。
- **`ArbPush` 可以发给任何 F。** 源码只发给 `alive_paxos_memberlist_` 中的成员。
- **upgrade 要求 learner 的日志和 leader 完全一致。** 源码允许小的差距，barrier 检查仍然保证安全。
- **不建模：** 磁盘永久丢失、租约读、add / remove / replace 成员、flashback（mode meta）、F 数为奇数的部署。
