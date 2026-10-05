# 仲裁副本 TLA+ 模型

OceanBase PALF 仲裁副本的单日志流模型，F 的个数可配，检查了 2F1A 和 4F1A：选举、Phase 1（reconfirm）、Phase 2（配置和日志）、degrade / upgrade、A 推送配置、F 和 A 的崩溃与重启。

- 设计：[`../docs/specs/2026-10-04-arbitration-tla-design.md`](../docs/specs/2026-10-04-arbitration-tla-design.md)
- 结果：[`results.md`](results.md)

| 文件 | 内容 |
|---|---|
| `Arbitration.tla` | 模型和全部性质 |
| `Arbitration.cfg` | 2F1A 安全性检查 |
| `ArbitrationBigPid.cfg`、`ArbitrationBigLog.cfg` | 2F1A 安全性检查，更大的边界 |
| `Arbitration4F.cfg` | 4F1A 安全性检查（约 6 小时） |
| `Liveness.cfg`、`Liveness4F.cfg` | 2F1A 和 4F1A 的活性检查：少数派异常时最终恢复服务 |
| `Coverage.cfg`、`Coverage4F.cfg` | 2F1A 和 4F1A 可达性见证的公共配置 |
| `LiveCoverage.cfg` | 活性场景见证的公共配置 |
| `run.sh` | `./run.sh <配置名>` 运行一个配置 |
| `check-witnesses.sh` | 逐条运行见证，每条都应输出 `REACHED`；用 `BASE=Coverage4F` 或 `BASE=LiveCoverage` 切换配置 |

依赖：
- Java 8 或更新版本：优先用环境变量 `JAVA`，其次是 Homebrew 的 OpenJDK（`/opt/homebrew/opt/openjdk/bin/java`），最后是 PATH 里的 `java`。
- TLC：默认 `../tools/tla2tools.jar`（TLC 2.14，随仓库提供），可用 `TLA2TOOLS` 覆盖。
