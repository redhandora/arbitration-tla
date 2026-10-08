# 仲裁副本 TLA+ 模型

OceanBase PALF 仲裁副本的单日志流模型，即论文里的 dual-quorum Paxos。全量副本的个数可配，检查了 2F1A 和 4F1A。模型覆盖选举、日志重确认（Prepare 阶段、日志恢复、StartWorking 日志）、配置确认、日志的接受与提交、降级和升级、A 推送配置与追赶提案编号，以及全量副本和 A 的崩溃与重启。

- 设计：[`../docs/specs/2026-10-04-arbitration-tla-design.md`](../docs/specs/2026-10-04-arbitration-tla-design.md)（写于改名之前，名称对照见下文）
- 结果：[`results.md`](results.md)

| 文件 | 内容 |
|---|---|
| `Arbitration.tla` | 模型和全部性质 |
| `Arbitration.cfg` | 2F1A 安全性检查 |
| `ArbitrationBigPid.cfg`、`ArbitrationBigLog.cfg` | 2F1A 安全性检查，更大的边界 |
| `Arbitration4F.cfg` | 4F1A 安全性检查（耗时很长） |
| `Pruned4F.tla`、`Pruned4F.cfg` | 4F1A 剪枝检查，覆盖 3 个提案编号：去掉 A 的推送、追赶和升级，崩溃后立即重启。每一步都是 `Spec` 的一步或两步，所以这里找到的违例一定可达 |
| `Liveness.cfg`、`Liveness4F.cfg` | 2F1A 和 4F1A 的活性检查：少数派异常时最终恢复服务 |
| `Coverage.cfg`、`Coverage4F.cfg` | 2F1A 和 4F1A 可达性见证的公共配置 |
| `LiveCoverage.cfg` | 活性场景见证的公共配置 |
| `run.sh` | `./run.sh <配置名>` 运行一个配置；`MODULE=Pruned4F ./run.sh Pruned4F` 运行剪枝检查 |
| `check-witnesses.sh` | 逐条运行见证，每条都应输出 `REACHED`；用 `BASE=Coverage4F` 或 `BASE=LiveCoverage` 切换配置 |

依赖：
- Java 8 或更新版本：优先用环境变量 `JAVA`，其次是 Homebrew 的 OpenJDK（`/opt/homebrew/opt/openjdk/bin/java`），最后是 PATH 里的 `java`。
- TLC：默认 `../tools/tla2tools.jar`（TLC 2.14，随仓库提供），可用 `TLA2TOOLS` 覆盖。

## 术语和名称

模型中的名称与论文第 5 节一致：

| 论文 | 模型 |
|---|---|
| 提案编号（proposal number，PALF 的 proposal_id） | `proposal[s]`：副本承诺过的最大提案编号，leader 的就是它自己的提案编号 |
| 日志提交成员组 S | `config[s].curr.commitGroup` |
| 选举成员组 E = S ∪ {A} | `ElectionGroup(s)` |
| Prepare 多数派（E 的多数派） | `IsPrepareQuorum(Q, c)` |
| Accept 多数派（S 的多数派） | `AcceptedBy(l, i, S)`、`CanCommitUpTo` |
| 副本对 leader 的确认（PALF 的 `match_lsn_map_`） | `matchIndex[l][f]`、`Acked(l, f, i)`：leader 只依据收到的确认判断提交和变更前同步，不读副本当前的日志 |
| Prepare 阶段 | `Prepare(c, p)`、`Promise(v, c)`，候选的角色是 `"Candidate"` |
| 日志恢复：从 (acc, LSN) 最大的副本拉日志 | `RecoverLog(c)`、`RecoverySources(Q)`、`Acc(f)`；之后角色是 `"Reconfirming"` |
| StartWorking 日志 | `StartWorking(l)`；提交后角色是 `"Leader"` |
| 配置确认 | `ConfirmConfig(l)`、`ConfigConfirmed(l)` |
| 降级、升级 | `Degrade(l, s)`、`Upgrade(l, m)` |
| 副本接受配置 / 接受日志 | `AcceptConfig(v, l)` / `AcceptEntry(f, l)` |
| barrier；截断过期日志 | `config[s].barrier`、`MatchesBarrier`；`TruncateStaleEntries` |
| 变更前同步 | `MajorityHoldsLeaderLog(l, S)`（`CanDegrade`、`Upgrade`、`StartWorking` 都要求） |
| 提交点冻结 | `CommitEntries` 要求 `pendingChange[l] = None` |

论文中的定理和引理对应的性质：

| 论文 | 性质 |
|---|---|
| 定理 1(a) leader completeness | `LeaderCompleteness`；`RecoveryComplete` 提前检查：任何现在能完成 Prepare 阶段的候选，都会恢复出全部已提交日志 |
| 定理 1(b) agreement | `Agreement` |
| 引理 2 | `ElectableConfigsAdjacent`：仍能选出 leader 的配置，日志提交成员组两两至多相差一个成员；推论 `OneLeaderPerProposal`、`OneActiveLeader` |
| 定理 2 liveness | `EventuallyStableLeader`、`WritesCommit`（`LiveSpec`） |

旧名称（设计文档，以及提交 `8c9d8ef` 及之前的版本）对照：

| 旧 | 新 |
|---|---|
| `pid`、`meta`、`promises`、`pq`、`cc`、`commitIdx` | `proposal`、`config`、`promisedBy`、`prepareConfig`、`pendingChange`、`commitIndex` |
| 配置字段 `sync`、`ver`；barrier 和日志条目字段 `idx`、`pid` | `commitGroup`、`version`；`index`、`proposal` |
| 常量 `MaxPid`、`MaxSeq` | `MaxProposal`、`MaxConfigSeq` |
| 角色 `"Prepare"`、`"Reconfirm"` | `"Candidate"`、`"Reconfirming"` |
| `Elect`、`Fetch`、`SendMeta`、`Replicate`、`Write`、`CommitLog` | `Prepare`、`RecoverLog`、`AcceptConfig`、`AcceptEntry`、`ClientWrite`、`CommitEntries` |
| `ArbPush`、`ArbCatchUpPid` | `ArbiterPushConfig`、`ArbiterAdoptProposal` |
| `AcceptedPid`、`LogAfterMeta`、`PassesBarrier`、`MaxLogServers`、`MajorityCaughtUp` | `Acc`、`TruncateStaleEntries`、`MatchesBarrier`、`RecoverySources`、`MajorityHoldsLeaderLog` |
| `QuorumIntersection`、`OneLeaderPerPid`、`NoDualPrimary`、`CommittedConsistent`、`ArbNotAhead`、`PidMonotonic` | `RecoveryComplete`、`OneLeaderPerProposal`、`OneActiveLeader`、`Agreement`、`ArbiterNotAhead`、`ProposalMonotonic` |
| 见证 `NoReconfirm`、`NoGhostTruncate`、`NoArbGhostTruncate`、`NoHalfSyncCommit`、`NoArb*` | `NoReconfirming`、`NoStaleTruncate`、`NoArbiterStaleTruncate`、`NoHalfGroupCommit`、`NoArbiter*` |
