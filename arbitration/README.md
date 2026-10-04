# 2F1A 仲裁副本 TLA+ 模型

OceanBase PALF 仲裁副本（2F1A）的单日志流模型：选举、Phase 1（reconfirm）、Phase 2（配置和日志）、degrade / upgrade、A 推送配置、F 和 A 的崩溃与重启。

- 设计：[`../docs/specs/2026-10-04-arbitration-tla-design.md`](../docs/specs/2026-10-04-arbitration-tla-design.md)
- 结果：[`results.md`](results.md)

| 文件 | 内容 |
|---|---|
| `Arbitration.tla` | 模型和全部性质 |
| `Arbitration.cfg` | 安全性检查 |
| `Liveness.cfg` | 活性检查：少数派异常时最终恢复服务 |
| `Coverage.cfg` | 安全性模型的可达性见证的公共配置 |
| `LiveCoverage.cfg` | 活性场景见证的公共配置 |
| `run.sh` | `./run.sh <配置名>` 运行一个配置 |
| `check-witnesses.sh` | 逐条运行见证，每条都应输出 `REACHED`；`BASE=LiveCoverage` 切换到活性模型 |

依赖：
- Java 8 或更新版本：优先用环境变量 `JAVA`，其次是 Homebrew 的 OpenJDK（`/opt/homebrew/opt/openjdk/bin/java`），最后是 PATH 里的 `java`。
- TLC：默认 `../tools/tla2tools.jar`（TLC 2.14，随仓库提供），可用 `TLA2TOOLS` 覆盖。
