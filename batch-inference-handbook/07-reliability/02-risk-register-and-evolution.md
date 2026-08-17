# 风险清单与演进优先级

## 1. P0/P1：会造成任务丢失、卡死或错误终态

| 风险 | 影响 | 建议 |
| --- | --- | --- |
| DB创建后只启本地TaskCreator goroutine | 进程退出时Task永久init | durable task-created event/outbox + Reconciler |
| Merge失败只打点并return | 全Shard完成但Task长期running | merge retry queue + merging状态 + Reconciler |
| 最后多个Shard跨副本重复Merge | 重复OSS IO、状态竞争 | per-task分布式锁/DB CAS |
| 状态更新不检查RowsAffected | 误报更新成功、竞态不可见 | tx内读写、检查RowsAffected/revision |
| FAIL/RUN_COMPLETE无条件转换 | 终态可被迟到事件覆盖 | 限定expected states和终态优先级 |
| 取消直接stopped | 状态机与执行观察不一致 | STOP→stopping→STOP_COMPLETE |
| TaskReconciler为空 | 卡死状态没有通用兜底 | 实现周期对账 |

## 2. P1：大任务稳定性与资源风险

| 风险 | 影响 | 建议 |
| --- | --- | --- |
| 输入下载两遍 | 带宽/源站压力和耗时翻倍 | 单遍临时分片+完成后manifest，或源文件落OSS |
| 执行阶段整Shard请求/响应常驻 | Shard过大时内存峰值 | 有界流式producer/consumer，结果分段落OSS |
| saveResults整Shard strings.Builder | 响应大时额外内存副本 | pipe/Multipart或流式JSONL writer |
| 每Shard完成全扫Metadata | O(S²) OSS请求 | 原子Reducer+最终全量校验 |
| Ready等待Background无deadline | 无Ready模型占住Shard | Task context/deadline贯穿 |
| 退避time.Sleep无jitter/cancel | 惊群且取消不及时 | full jitter + context timer |
| 部分Shard入队后后续入队失败 | Task failed但已入队Shard仍执行 | manifest commit后原子发布/补偿删除 |

## 3. P1：控制闭环风险

| 风险 | 影响 | 建议 |
| --- | --- | --- |
| Controller map并发读写无锁 | data race/panic | immutable snapshot/atomic/RWMutex |
| `waiting>0,running=0`记missing | 严重停滞未rollback | stalled最高优先级信号 |
| service_instance_num静态 | 容量分摊不准 | 实时发现Batch Ready副本 |
| Redis写失败不回退本地窗口 | 暂时缺指标/停止调谐 | 明确failover或降级状态 |
| 上界变化reset禁用 | 大扩缩容后历史状态可能不适配 | 评估后恢复reset/冷却策略 |
| 0值被Runtime转默认 | 无法按控制面语义暂停 | 独立paused字段/统一0定义 |

## 4. P1/P2：消息和通知

- 逐请求 Kafka 没有 durable outbox，可能丢/重；
- Message 模式最终文件只合并第一个 Shard；
- Compute Finish Notice 早于 Result Ready；
- 发送失败不影响 Task 终态，用户可能看到 completed 但消息不全；
- 通知与业务结果需分别定义幂等 key 和消费契约。

## 5. P1：安全与敏感信息

代码启动时记录整个 `config.Global()`，Config 的字符串化会包含 Gateway Key、OpenAPI token、存储配置等敏感值。仓库中的运维记录也可能包含仍在有效期内的预签名下载链接。

建议立即：

- 配置对象实现 `RedactedString()`，敏感字段只显示末4位；
- 禁止整对象日志，按白名单打印非敏感字段；
- Secret 只从密钥系统/环境注入，不给示例真实默认值；
- CI secret scanning；
- 文档中的预签名URL、账号、Bucket和内部Token统一脱敏；
- 对已暴露凭证/链接按安全流程轮换或失效。

本手册不复制任何凭证和预签名 URL。

## 6. P2：代码与架构清理

- 镜像只启动 apiserver，但仓库保留独立 scheduler 命令，容易误解部署；
- `pkg/taskprocessor` 是另一套未装配实现，与 manager 重复；
- `pkg/statemanager`、TaskReconciler 等骨架未完成；
- 旧 DB TaskShard 方法仍在 Executor，但主流程用 OSS Metadata；
- README 与真实进程边界需要同步；
- TODO 注释中有些已经实现、有些是真缺口，应转为 issue/ADR。

## 7. 推荐演进路线

### 阶段一：消灭卡死

1. Task create outbox；
2. merging 状态、Merge 锁和重试；
3. 通用 Reconciler；
4. 统一状态机 CAS。

### 阶段二：控制资源峰值

1. Shard 内有界 streaming pipeline；
2. 结果分段写；
3. 增量进度 Reducer；
4. Task context 全链路传播。

### 阶段三：完善交付

1. Kafka outbox/manifest；
2. 消息与文件契约统一；
3. 对账、补发、DLQ；
4. exactly-once effect 与计费幂等。

### 阶段四：控制器工程化

1. 决策历史库与 replay；
2. stopped queue 信号、KV/Token 指标；
3. 动态服务实例数；
4. 模型/卡型 profile和自动灰度。

## 8. 讲风险的方式

面试时先说明当前机制为何有效，再说明边界和改进：

> 现有heartbeat能恢复升级中的Shard，确定性Key能让结果覆盖，因此在当前规模下保障了可用性；但语义是at-least-once，且Merge缺少跨实例锁。下一步我会优先加Task Reconciler和per-task lease，把“可恢复”升级为“可自动收敛”。

不要只列缺陷，也不要把尚未实现的改进说成已有能力。

