# arbitration-tla

OceanBase PALF 仲裁副本的 TLA+ 模型，检查了 2F1A 和 4F1A：一个日志流上的选举、日志重确认（Prepare 阶段、日志恢复、StartWorking 日志）、配置确认、日志的接受与提交、降级和升级、仲裁副本推送配置，以及全量副本和仲裁副本的崩溃与重启。模型依据 OceanBase 源码 `src/logservice/palf`（提交 `0fa1778`），名称与论文的术语一致（对照见 [`arbitration/README.md`](arbitration/README.md)）。

## 检查了什么

- **安全性**：已提交的日志不丢、不被覆盖（定理 1：leader completeness 和 agreement）；仍能选出 leader 的配置两两相邻（引理 2），因此每个提案编号至多一个 leader、至多一个 leader 能推进提交点；仲裁副本的配置不会领先到全量副本追不上；以及 LogMatching 和几条单调性。
- **活性**：少数派异常时，系统最终恢复服务（定理 2）。
- **可达性见证**：降级、配置确认、升级、换 leader、过期日志截断、单副本窗口等关键路径都确实可达，保证上面的性质不是空洞地成立。

结果见 [`arbitration/results.md`](arbitration/results.md)。

## 运行

需要 Java 8 或更新版本。TLC（`tools/tla2tools.jar`，TLC 2.14，MIT 许可）随仓库提供。

```bash
cd arbitration
./run.sh Arbitration          # 2F1A 安全性
./run.sh Arbitration4F        # 4F1A 安全性（耗时很长）
MODULE=Pruned4F ./run.sh Pruned4F   # 4F1A 剪枝检查，3 个提案编号
./run.sh Liveness             # 2F1A 活性
./run.sh Liveness4F           # 4F1A 活性
./check-witnesses.sh          # 可达性见证，每条都应输出 REACHED
BASE=LiveCoverage ./check-witnesses.sh NoServingAfterFCrash \
  NoServingAfterLeaderCrash NoServingAfterArbiterCrash
```

## 目录

| 路径 | 内容 |
|---|---|
| `arbitration/` | 模型、配置、脚本和结果，说明见 [`arbitration/README.md`](arbitration/README.md) |
| `docs/specs/` | 设计文档：建模范围、状态、动作、不变式和活性前提 |
| `tools/` | TLC |
