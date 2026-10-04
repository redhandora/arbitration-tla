# TLC 结果

日期：2026-10-04。TLC 2.14（`tools/tla2tools.jar`），OpenJDK 27，8 个 worker。规格 `Arbitration.tla`，共 651 行。

模型发现的两个问题，以及模型里采用的修正，见 [`findings.md`](findings.md)。下面的结果都基于修正后的模型。

## 安全性（`Arbitration.cfg`）

边界：F = {f1, f2}，A = a，MaxPid = 3，MaxLogLen = 2，MaxSeq = 4；F 对称。

| 项目 | 值 |
|---|---|
| 结果 | 通过 |
| 生成状态 | 10,575,316 |
| 不同状态 | 2,681,670 |
| 搜索深度 | 42 |
| 耗时 | 30 秒 |

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

## 活性（`Liveness.cfg`）

边界：F = {f1, f2}，A = a，MaxPid = 3，MaxLogLen = 1，MaxSeq = 4；不用对称。

| 项目 | 值 |
|---|---|
| 性质 | `EventuallyServing == <>[](\E l \in F : Serving(l))` |
| 结果 | 通过 |
| 不同状态 | 1,028 |
| 搜索深度 | 20 |
| 耗时 | 5 秒 |

前提（只用于活性，安全性检查不加）：
- 异常是少数派，且不恢复；
- 选举最终稳定：有存活的非 Follower F 时，其他 F 不发起选举；
- 故障检测最终准确：只 degrade 真正宕机的 F；
- 除写入和崩溃外，所有动作弱公平。

非空洞性：
- 同样的边界下，用不带公平性的 `Spec` 检查 `EventuallyServing`，TLC 报违例（系统可以一直不动）。这说明通过是公平性和协议共同作用的结果。
- 下表的三个活性场景在 `LiveSpec` 下都会发生。

## 可达性见证

每条见证写成"某状态不存在"，TLC 找到反例即代表该路径可达。8 个 worker 并行时，轨迹不一定最短。

安全性模型（`Coverage.cfg`，边界同安全性检查，不用对称）：

| 见证 | 证明可达的路径 | 轨迹长度 |
|---|---|---|
| NoReconfirm | Phase 1 能完成拉日志 | 4 |
| NoLeader | reconfirm 能完成 | 7 |
| NoArbPush | A 推送配置会被触发 | 8 |
| NoCommittedEntry | 日志能提交 | 10 |
| NoDegradeCommitted | degrade 提交后还能提交日志 | 12 |
| NoUpgradeAfterDegrade | learner 追上已提交日志后被 upgrade | 16 |
| NoReconfirmAfterDegrade | degrade 后换 pid 重新 reconfirm，恢复已提交日志 | 15 |
| NoGhostTruncate | ghost 日志截断会被触发 | 12 |
| NoLearnerWindow | 单副本窗口：唯一的同步 F 宕机，存活的 learner 缺少已提交日志 | 13 |

活性模型（`LiveCoverage.cfg`，边界同活性检查）：

| 见证 | 证明发生的场景 | 轨迹长度 |
|---|---|---|
| NoServingAfterFCrash | 一个 F 宕机后，幸存者 degrade 它并继续服务 | 11 |
| NoServingAfterLeaderCrash | 原 leader 宕机后，新 leader 恢复其日志并服务 | 19 |
| NoServingAfterArbCrash | A 宕机后继续服务 | 8 |

## 复现

```bash
cd arbitration
./run.sh Arbitration                       # 安全性
./run.sh Liveness                          # 活性
./check-witnesses.sh                       # 安全性模型的 9 条见证
BASE=LiveCoverage ./check-witnesses.sh NoServingAfterFCrash \
  NoServingAfterLeaderCrash NoServingAfterArbCrash   # 活性场景
```

## 边界调整记录

无。全部检查都在设计文档的默认边界下完成。

## 模型修改记录（实现过程中）

| 修改 | 原因 |
|---|---|
| `Promise` 增加配置版本过滤 | 作者决定，修正问题 1（见 `findings.md`） |
| ghost 裁剪阈值改用 meta 自己的 pid | 作者选择修法 3，修正问题 2（见 `findings.md`） |
| `ArbPush` 要求所有 F 都是 Follower | A 只有作为选举 leader 才推送，此时没有 F 处于 leader 角色 |
| `PassesBarrier` 用 IF 而不是 `\/` | TLC 在 action 里会求值 `\/` 的每个分支，原写法越界 |
| `PrepareStuck` 同样考虑版本过滤 | 与 `Promise` 一致，否则被过滤的候选永远无法重试 |

## 已知的模型简化

- 不跟踪 follower 已知的提交点：ghost 裁剪比源码略宽（源码只截还在 sliding window 里的日志）。
- `MajorityCaughtUp` 和 `AckedBy` 直接看副本的日志内容，包括已宕机副本持久化的日志，相当于 leader 总能知道副本已有哪些日志。对安全性是放宽，会多出行为。
- 安全性模型不建模 lease，允许多个选举 leader 并存；配置路径的安全性依靠 `Promise` 的配置版本过滤（问题 1）。
