# Batch Inference 项目手册

这套手册用于在无法访问源码时，仍能完整理解 batch-inference 的架构、关键链路、实现逻辑、故障语义、性能取舍和项目经历表达。

它不是源码目录说明，而是以两条闭环组织内容：

1. 任务执行闭环：创建任务 → 流式读取 JSONL → 动态分片 → Redis 调度 → 并发推理 → 进度统计 → 结果合并与交付。
2. 容量控制闭环：采集 Ready 容量与运行指标 → 生成调谐信号 → 调整 KConf → 动态修改执行并发 → 继续观测效果。

## 文档快照

| 项目 | 值 |
| --- | --- |
| Git 分支 | `master` |
| Git Commit | `09ca42d0e4fc3fabbbd088e61823ace0b8154710` |
| Commit 时间 | 2026-08-04T07:10:11Z |
| 手册开始整理日期 | 2026-08-17 |
| 代码语言 | Go 1.23 |
| 主要组件 | Gin、GORM、Redis、S3、Kafka、KConf、ants、OpenAI-compatible Gateway |

本文档不保存任何 Token、AccessKey、SecretKey 或内部鉴权值。

## 实现状态标识

手册会严格区分以下状态：

| 标识 | 含义 |
| --- | --- |
| `Implemented` | 已接入当前启动链路的实现 |
| `Designed` | 有设计文档，但当前代码快照尚未接入 |
| `Legacy` | 历史实现或未装配代码 |
| `Risk` | 从实现中识别出的边界、一致性或运维风险 |
| `Inference` | 根据入口、构建脚本和调用关系得出的部署推断 |
| `Experience Result` | 来自项目实践的线上结果，不是源码可证明的数据 |

## 三种阅读方式

### 快速复习

阅读 [QUICK_REFERENCE.md](./QUICK_REFERENCE.md)，用于面试前快速回忆系统主线、关键公式和高频问题。

### 按链路深入

推荐顺序：

1. [系统介绍](./00-overview/01-system-introduction.md)
2. [运行时架构](./00-overview/02-runtime-architecture.md)
3. [端到端链路](./00-overview/03-end-to-end-flows.md)
4. [任务状态机](./01-domain-model/03-task-state-machine.md)
5. `02-task-ingestion/`：大文件接入与动态分片
6. `03-scheduling/`：Redis 调度与两级并发
7. `04-execution/`：模型请求执行
8. `05-progress-and-results/`：实时进度与结果合并
9. `06-concurrency-autotuner/`：并发自动探测闭环
10. `07-reliability/`：一致性、幂等和故障恢复
11. `10-experience-and-interview/`：项目总结和面试材料

### 全文检索

最终合并版本位于 `FULL_HANDBOOK.md`。模块化 Markdown 是事实源，合并文档用于离线保存和全文搜索。

本次整理的链接、敏感信息扫描和测试边界见 [VERIFICATION.md](./VERIFICATION.md)。

## 问题导航

| 想回答的问题 | 推荐文档 |
| --- | --- |
| 系统整体是怎么运行的？ | `00-overview/02-runtime-architecture.md` |
| 一条任务从提交到完成经历什么？ | `00-overview/03-end-to-end-flows.md` |
| 为什么能支持 20GB JSONL？ | `02-task-ingestion/02-jsonl-streaming-download.md`、`04-dynamic-sharding-and-oss-layout.md` |
| 网络断流为什么可能表现成 JSON 错误？ | `02-task-ingestion/03-jsonl-validation-and-error-classification.md` |
| 多实例如何避免领取同一个 Shard？ | `03-scheduling/02-shard-claim-and-dispatch.md` |
| Shard 并发与请求并发有什么区别？ | `03-scheduling/03-two-level-concurrency-control.md` |
| 实例升级时正在执行的 Shard 怎么恢复？ | `03-scheduling/04-failed-retry-and-upgrade-recovery.md` |
| 请求如何调用模型网关？ | `04-execution/02-request-execution-and-gateway.md` |
| 哪些错误会重试？ | `04-execution/03-retry-backoff-and-error-handling.md` |
| 实时进度为什么放 Redis？ | `05-progress-and-results/01-realtime-progress.md` |
| S3 Multipart 合并如何控制内存？ | `05-progress-and-results/04-s3-multipart-streaming-merge.md` |
| 并发自动探测的公式是什么？ | `06-concurrency-autotuner/03-capacity-upper-bound.md` |
| 12.1% → 1.8% 和 37% → 71% 怎么讲？ | `06-concurrency-autotuner/06-gray-release-results-and-analysis.md` |
| MySQL、Redis、OSS 谁是事实源？ | `01-domain-model/04-data-ownership.md` |
| 任务卡住时怎么排查？ | `07-reliability/03-failure-recovery-matrix.md` |
| 面试时如何介绍项目？ | `10-experience-and-interview/01-project-summary.md` |

## 内容边界

当前镜像入口只启动 `apiserver`，但 `apiserver` 内部同时启动 API、TaskCreator、Scheduler、Executor、自动调谐和监控任务。因此本手册把当前运行形态描述为“多副本单体式编排服务”。仓库中独立 `scheduler` 二进制、`pkg/taskprocessor`、`pkg/statemanager` 和空的 TaskReconciler 会作为未装配或遗留实现单独说明。

私有模型二阶段“任务窗口资源池调度”属于 `Designed`，不会与当前实现混写。

## 项目经历中的确定成果

以下内容来自项目实践，必须出现在项目总结中：

- 重构 JSONL 任务处理链路，实现流式下载、动态分片和 S3 Multipart 流式结果合并，支持 20GB 单文件处理。
- 开发模型并发自动探测机制，基于网关成功率、队列负载等信号形成闭环自动调谐。
- 核心离线模型灰度期间，容量相关失败率从 12.1% 降至 1.8%。
- KV Cache 平均利用率从 37% 提升至 71%。

这些结果在手册中标记为 `Experience Result`，并与可由源码验证的实现机制分开描述。
