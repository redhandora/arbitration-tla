# arbitration-tla

OceanBase PALF 仲裁副本（2F1A）的 TLA+ 模型：一个日志流上的选举、Phase 1（reconfirm）、Phase 2（配置变更和日志）、degrade / upgrade、仲裁副本推送配置，以及 F 和 A 的崩溃与重启。模型依据 OceanBase 源码 `src/logservice/palf`（提交 `0fa1778`）。

## 检查了什么

- **安全性**：quorum 相交（I1）、不出现双主（I2）、已提交的日志不丢（I3）、仲裁副本的配置不会领先到 F 追不上（I4），以及 LogMatching 和几条单调性。
- **活性**：少数派异常时，系统最终恢复服务。
- **可达性见证**：degrade、upgrade、换 leader、ghost 日志截断、单副本窗口等关键路径都确实可达，保证上面的性质不是空洞地成立。

结果见 [`arbitration/results.md`](arbitration/results.md)。

## 发现的问题

TLC 找到了两个问题，详见 [`arbitration/findings.md`](arbitration/findings.md)，反例轨迹在 `arbitration/findings/`：

1. Phase 1（prepare）不检查配置版本：候选当选后配置被另一个 leader 修改，它仍能用旧配置完成 reconfirm，导致双主。
2. 仲裁副本作为选举 leader 推送配置时，用自己当前的 proposal_id 作为 ghost 日志的裁剪阈值，可能截掉已提交的日志，一个 F 故障后数据丢失。

模型对两者都做了修正，修正后全部性质通过。

## 运行

需要 Java 8 或更新版本。TLC（`tools/tla2tools.jar`，TLC 2.14，MIT 许可）随仓库提供。

```bash
cd arbitration
./run.sh Arbitration          # 安全性
./run.sh Liveness             # 活性
./check-witnesses.sh          # 可达性见证，每条都应输出 REACHED
BASE=LiveCoverage ./check-witnesses.sh NoServingAfterFCrash \
  NoServingAfterLeaderCrash NoServingAfterArbCrash
```

## 目录

| 路径 | 内容 |
|---|---|
| `arbitration/` | 模型、配置、脚本、结果和问题记录，说明见 [`arbitration/README.md`](arbitration/README.md) |
| `docs/specs/` | 设计文档：建模范围、状态、动作、不变式和活性前提 |
| `tools/` | TLC |
