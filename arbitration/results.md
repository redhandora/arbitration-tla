# TLC 结果

日期：2026-10-07 至 2026-10-08。TLC 2.14（`tools/tla2tools.jar`），OpenJDK 27，8 个 worker。规格 `Arbitration.tla`，共 933 行（含注释）。术语与论文第 5 节一致，名称对照见 [`README.md`](README.md)。

模型不建模选举 lease，允许多个选举 leader 同时存在。Prepare 阶段按候选发起选举时的配置版本过滤承诺，这是对"选举时投票方忽略 membership_version 更低的请求"的抽象。

所有检查都基于同一份 `Spec` / `LiveSpec`（`Pruned4F` 是 `Spec` 的子集，见下文）。见证的定义不影响这两个规格的状态空间。

## 安全性

| 配置 | 部署 | MaxProposal | MaxLogLen | MaxConfigSeq | 不同状态 | 生成状态 | 深度 | 耗时 | 结果 |
|---|---|---|---|---|---|---|---|---|---|
| `Arbitration.cfg` | 2F1A | 3 | 2 | 4 | 4,359,408 | 18,353,856 | 41 | 1 分 | 通过 |
| `ArbitrationBigPid.cfg` | 2F1A | 4 | 2 | 4 | 18,798,970 | 80,597,583 | 48 | 4 分 27 秒 | 通过 |
| `ArbitrationBigLog.cfg` | 2F1A | 3 | 3 | 5 | 24,564,480 | 103,719,388 | 48 | 5 分 12 秒 | 通过 |
| `Pruned4F.cfg`（剪枝） | 4F1A | 3 | 1 | 4 | 357,009,309 | 2,590,397,126 | 29（截止） | 6 小时 58 分 | 深度 ≤ 29 无违例 |
| `Arbitration4F.cfg` | 4F1A | 2 | 1 | 4 | 865,722,245 | 5,815,786,009 | 30（截止） | 17 小时 11 分 | 深度 ≤ 30 无违例 |

都开了全量副本的对称性。4F1A 的 MaxConfigSeq 从 3 提到 4：配置确认多占一个序号，两任 leader 各做一次确认和一次降级需要 4 个。

两项 4F1A 检查在这台机器（10 核，24 GB 内存，约 100 GB 可用磁盘）上跑不完，按深度截止：宽度优先搜索在深度 d 全部完成后停止，结论是"深度不超过 d 的所有状态都满足全部性质"。`Pruned4F` 截止时每层状态数仍以约 1.4 倍增长（深度 22：2286 万，25：8664 万，28：2.60 亿，29：3.57 亿）；`Arbitration4F` 也一样（深度 27：3.48 亿，28：4.93 亿，29：6.68 亿，30：8.66 亿），总量都在 10 亿以上。作为参照：去掉配置确认（删掉 `Degrade` 中的 `ConfigConfirmed(l)`）后，`Arbitration4F` 在 11 步报 `ElectableConfigsAdjacent` 违例；不查这条性质时，在 21 步报出丢失已提交日志的执行（即论文 Example 1，副本编号不同），都在截止深度之内。

`Pruned4F` 是 `Spec` 的剪枝子集：去掉 A 的推送和追赶、去掉升级，崩溃后立即重启（`Bounce`，相当于 `Crash` 加 `Restart` 两步）。每一步都是 `Spec` 的一步或两步，所以它找到的违例在 `Spec` 中一定可达；它能把 4F1A 检查到 3 个提案编号，而完整的 `Spec` 在 4F1A 上只能检查到 2 个。

检查的性质：

| 性质 | 论文 | 含义 |
|---|---|---|
| TypeOK | | 类型正确 |
| LogMatching | | 同一 LSN 上提案编号相同的两条日志，之前的日志完全一样 |
| LeaderCompleteness | 定理 1(a) | leader 持有所有提案编号不高于自己的已提交日志 |
| RecoveryComplete | 定理 1(a) | 任何现在能完成 Prepare 阶段的候选，无论用哪个 Prepare 多数派，恢复出的日志都包含全部已提交日志 |
| Agreement | 定理 1(b) | 同一 LSN 不会以两个不同的提案编号被提交 |
| ElectableConfigsAdjacent | 引理 2 | 仍能选出 leader 的配置（某个成员持有它，且它的选举成员组中多数派没有更新的版本），日志提交成员组两两至多相差一个成员 |
| OneLeaderPerProposal | 引理 2 的推论 | 每个提案编号至多一个副本完成 Prepare 阶段 |
| OneActiveLeader | 引理 2 的推论 | 任一时刻至多一个 leader 能推进提交点 |
| ArbiterNotAhead | | A 的配置不会领先到其日志提交成员组的多数派追不上；A 持有确认配置时，允许落后的是即将被降级的那一个成员 |
| CommittedMonotonic | | 已提交集合只增不减 |
| ProposalMonotonic | | 每个副本承诺的提案编号只增不减 |
| ConfigVersionMonotonic | | 每个副本的配置版本只增不减 |

`ElectableConfigsAdjacent` 是一个上近似：它不看副本是否存活、也不看承诺过的提案编号，只看配置版本。所以它比"实际能选出 leader 的配置相邻"更强。两两相邻的成员组至多两个，正是引理 2 说的"最近一次落定的配置，加上在它之上进行中的一次变更"。

## 活性

| 配置 | 部署 | MaxProposal | MaxLogLen | MaxConfigSeq | 不同状态 | 深度 | 耗时 | 结果 |
|---|---|---|---|---|---|---|---|---|
| `Liveness.cfg` | 2F1A | 3 | 1 | 4 | 1,292 | 23 | 5 秒 | 通过 |
| `Liveness4F.cfg` | 4F1A | 5 | 1 | 7 | 5,741,034 | 49 | 25 分 35 秒 | 通过 |

不用对称性（TLC 在对称下做活性检查不可靠）。

检查的性质（定理 2）：
- `EventuallyStableLeader == <>[](\E l \in F : StableLeader(l))`：最终总有一个存活的 leader，没有进行中的配置变更，日志提交成员组的多数派存活，并且一直保持。
- `WritesCommit`：leader 写下的每个位置，只要它一直是存活的 leader，最终都会提交。按位置逐个表述，不依赖写入有上限。

前提（只用于活性，安全性检查不加），从初始状态起一直成立：
- 异常是少数派，且不恢复；
- 选举稳定：有存活的非 Follower 全量副本时，其他全量副本不发起选举，A 也不作为选举 leader 推送配置；卡住且已不可能当选的候选退回 Follower；
- 故障检测准确：只降级真正宕机的全量副本；leader 只在有宕机成员要降级时才做配置确认；
- 除写入和崩溃外，所有动作弱公平。

所以结论是"从全部正常出发，少数派异常时最终恢复服务"。"先混乱、后稳定"的情况没有覆盖。

**边界的依据：** 活性模型最多坏 2 个副本（4F1A，5 个中的少数派），最多换 2 次 leader，一共 3 个 leader：
- 配置序号最多 7 个：3 条 StartWorking 日志，2 次配置确认，2 次降级；
- 提案编号最多 5 个：3 次选举，加 2 次重试。

2F1A 最多坏 1 个副本，最多 2 个 leader：配置序号 ≤ 4（2 条 StartWorking 日志、1 次确认、1 次降级），提案编号 ≤ 3。

**非空洞性（去掉某个机制后检查应当失败）：**

| 改动 | 部署 | 结果 |
|---|---|---|
| 不带公平性的 `Spec` | 2F1A | 违例（系统可以一直不动），13 步 |
| 去掉 `DegradeLive` 的弱公平 | 2F1A | 违例，10 步 |
| 去掉 `CommitEntries` 的弱公平 | 2F1A | 违例，11 步 |
| 去掉 `ConfirmLive` 的弱公平 | 2F1A | 违例，16 步 |
| 去掉 `ConfirmLive` 的弱公平 | 4F1A | 违例，19 步 |
| 去掉 A 追提案编号（`ArbiterAdoptProposal`） | 4F1A | 违例：两个全量副本故障后选举卡死，约 31 万个状态，1 分 12 秒 |

去掉 `ConfirmLive` 的弱公平后两种部署都违例：宕机的副本不会再确认日志，新 leader 凑不齐 StartWorking 日志需要的确认，只能先确认配置、再降级。所以配置确认在恢复服务的必经路径上，活性检查覆盖了它。

## 可达性见证

每条见证写成"某状态不存在"，TLC 找到反例即代表该路径可达。8 个 worker 并行时，轨迹不一定最短。

| 见证 | 证明可达的路径 | 2F1A 步数 | 4F1A 步数 |
|---|---|---|---|
| NoReconfirming | Prepare 阶段能完成，进入日志恢复之后 | 4 | — |
| NoLeader | 日志重确认能完成 | 7 | 9 |
| NoArbiterPush | A 推送配置会被触发 | 6 | 7 |
| NoArbiterPushBesideLeader | 有全量副本处于 leader 角色时 A 仍可推送（不依赖 lease） | 7 | 7 |
| NoArbiterAdopt | A 追上更大的提案编号 | 7 | 8 |
| NoCommittedEntry | 日志能提交 | 10 | 14 |
| NoDegradeCommitted | 降级提交后还能提交日志 | 12 | 16 |
| NoDegradeAfterConfirm | 新 leader 确认配置后，在日志重确认期间降级 | 8 | 12 |
| NoHalfGroupCommit | 日志提交成员组降到一半的全量副本后还能提交（4F1A 需要两次降级） | — | 21 |
| NoCommitWithFAndArbiterDown | 一个全量副本和 A 同时宕机，不降级也能提交（只在 4F1A 可达） | — | 17 |
| NoUpgradeAfterDegrade | learner 追上已提交日志后被升级 | 16 | 22 |
| NoReconfirmAfterDegrade | 降级后换提案编号重新做日志重确认，恢复已提交日志 | 17 | 22 |
| NoStaleTruncate | leader 发配置时会截断过期日志 | 12 | 16 |
| NoArbiterStaleTruncate | A 推送配置时会截断过期日志 | 13 | 16 |
| NoLearnerWindow | 单副本窗口：日志提交成员组的全量副本全部宕机，存活的 learner 缺少已提交日志 | 13 | 18 |

2F1A 用 `Coverage.cfg`（边界同 `Arbitration.cfg`，不用对称），4F1A 用 `Coverage4F.cfg`（边界同 `Arbitration4F.cfg`，用对称）。"—"表示没有在该部署上运行，或者该部署下不可达。

活性场景（`LiveCoverage.cfg`，2F1A，边界同 `Liveness.cfg`）：

| 见证 | 证明发生的场景 | 步数 |
|---|---|---|
| NoServingAfterFCrash | 一个全量副本宕机后，幸存者降级它并继续服务 | 11 |
| NoServingAfterLeaderCrash | 原 leader 宕机后，新 leader 恢复其日志、确认配置、降级原 leader 并服务 | 22 |
| NoServingAfterArbiterCrash | A 宕机后继续服务 | 8 |

## 复现

```bash
cd arbitration
./run.sh Arbitration                  # 2F1A 安全性
./run.sh ArbitrationBigPid            # 2F1A，MaxProposal 4
./run.sh ArbitrationBigLog            # 2F1A，MaxLogLen 3，MaxConfigSeq 5
MODULE=Pruned4F ./run.sh Pruned4F     # 4F1A 剪枝检查，3 个提案编号（不截止的话超过 7 小时）
./run.sh Arbitration4F                # 4F1A 安全性（不截止的话超过 17 小时）
./run.sh Liveness                     # 2F1A 活性
./run.sh Liveness4F                   # 4F1A 活性（约 26 分钟）
./check-witnesses.sh                  # 2F1A 见证，每条都应输出 REACHED
BASE=Coverage4F ./check-witnesses.sh NoLeader NoHalfGroupCommit NoCommitWithFAndArbiterDown ...
BASE=LiveCoverage ./check-witnesses.sh NoServingAfterFCrash \
  NoServingAfterLeaderCrash NoServingAfterArbiterCrash
```

`run.sh` 默认使用 12 GB 堆。两个大检查（4F1A 安全性、4F1A 活性）不要同时运行。

## 已知的模型简化

- **不建模选举 lease。** 允许多个选举 leader 同时存在；配置路径的安全性依靠 `Promise` 的配置版本过滤。
- **共享状态模型。** 一个副本直接读另一个副本的当前状态，覆盖不到迟到或重复的旧消息。
- **不跟踪 follower 已知的提交点。** 截断过期日志比源码略宽（源码只截还在 sliding window 里的日志）。
- **leader 只依据确认判断提交和变更前同步（`matchIndex`）。** 确认在副本接受日志时产生，leader 成为 leader、退位或宕机时清零；副本之后被别的 leader 截断，旧确认仍保留，和 `match_lsn_map_` 一样。
- **日志恢复读取的是 Prepare 阶段结束时副本的状态。** `RecoverLog` 按承诺者当前的 (acc, LSN) 选恢复源，而不是承诺时应答里带的快照。承诺之后，副本的日志只会被提案编号更大的 leader 改动。
- **A 的推送可以发给任何全量副本。** 源码只发给 `alive_paxos_memberlist_` 中的成员。
- **升级要求 learner 的日志和 leader 完全一致。** 源码允许小的差距，barrier 检查仍然保证安全。
- **配置确认。** 提交条件与其他配置变更相同（新配置选举成员组的多数派），barrier 在 leader 日志的末尾。
- **不建模：** 磁盘永久丢失、租约读、add / remove / replace 成员、flashback（mode meta）、全量副本数为奇数的部署。
