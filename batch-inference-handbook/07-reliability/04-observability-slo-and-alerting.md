# 可观测性、SLO 与告警

## 1. 四层指标

### API/Task

- 创建请求成功率和延迟（需从HTTP框架/Access Log补齐）；
- `task_finish{task_result=success|fail}`；
- 各状态 Task 数与停留时间；
- completion window 内完成率；
- `db_task_update_failed`；
- `oss_task_merge_failed`。

### Queue/Shard

- `pending_queue_counter`、`process_queue_counter`、`failed_queue_counter`；
- `shard_create`、`shard_add_queue`；
- `execute_shard_fail{fail_reason}`；
- `retry_shard_in_fail_queue`；
- `time_out_shard_in_fail_queue`；
- upgrade recovered shard数。

### Request/Gateway

- `request_count`、`request_final_counter{req_result}`；
- `request_cost` 与 `request_cost_with_retry`；
- 429/529/5xx容量失败率；
- waiting/running queue ratio；
- 请求重试次数分布（当前缺显式指标，建议补）；
- token吞吐、KV Cache、GPU指标（来自模型侧）。

### Control Plane

- `model_concurrency_reconcile_success/fail/fetch_fail`；
- Gateway sample too small/Redis write failed；
- `model_config_update`、goroutine/shard前后值；
- excluded KSN capacity；
- decision类型与target/upper bound（当前主要日志，建议指标化）。

## 2. 建议 SLO

| SLO | 示例定义 |
| --- | --- |
| 接入可用性 | 合法Create请求成功率 |
| 调度及时性 | P99 pending等待时间 |
| 窗口完成率 | completion window内终态Task比例 |
| 请求质量 | Batch 2xx/(2xx+429+5xx) |
| 结果可用性 | completed Task的output对象可读比例 |
| 消息完整性 | 期望请求数与成功投递/对账数一致率 |
| 控制器正确性 | KConf写后规定时间内所有实例cap收敛比例 |

不要只以 Task completed 作为结果 SLO；还要验证对象存在、行数/计数和消息交付。

## 3. 高价值告警

### 立即告警

- running Task 全部 Shard completed 超过 N 分钟；
- init Task 超过正常分片 P99；
- `oss_task_merge_failed > 0`；
- process heartbeat过期但未恢复；
- 容量失败率超过阈值且 AutoTuner未rollback；
- KConf更新失败/Watcher未收敛；
- Task completed但输出对象不存在。

### 趋势告警

- pending queue持续增长；
- failed queue年龄逼近最大重试窗口；
- Redis进度和MySQL/OSS计数差距扩大；
- Gateway success样本长期不足；
- excluded Ready Capacity占比过高；
- KV Cache利用率长期低或OOM/排队同时升高。

## 4. 结构化日志字段

所有关键事件建议统一：

```text
trace_id / task_id / shard_index / request_id
model_id / model_service_name / ksn / pool
attempt / event / old_status / new_status
queue / queue_value_hash
duration_ms / error_class / retryable
config_revision / current / target / upper_bound
```

当前很多日志有 taskID/model/queueKey，但 error reason直接做高基数 metric tag可能导致指标基数爆炸。应将错误归一为有限 `error_class`，完整文本留日志。

## 5. 分布式追踪

Batch Request ID 已通过 Gateway header传递，可作为跨系统关联键。推荐链路：

```text
Create API trace
  → Task/Shard span links
  → Gateway request span
  → OSS/Kafka event
```

百万请求 Task不宜创建一个包含百万 child span的单trace；可以按Shard采样，并保留每请求结构化日志/指标。

## 6. 控制器可解释性看板

同一时间轴展示：

- Ready replicas和card type；
- raw/effective upper bound；
- current/target goroutine；
- success rate及good/bad阈值；
- queue ratio及阈值；
- decision；
- 429/529/5xx；
- KV Cache与token throughput；
- KConf revision。

这样才能回答“为什么13:05从220降到170，以及是否有效”。

## 7. 数据保留

Redis AutoTuner last result默认仅21分钟，无法支撑长期复盘。建议决策事件进入持久时序库，至少保留一个发布周期；敏感标识做脱敏，绝不保存 API Key/token 或预签名URL。

## 8. 面试表达

> 我会把观测拆成Task、Queue/Shard、Request/Gateway和控制面四层。高价值告警不是“错误日志多了”，而是状态不收敛，例如全Shard completed但Task仍running、output不存在、heartbeat过期未恢复。自动调谐还要有解释性看板，把上界、信号、decision、KConf revision和KV Cache放在同一时间轴。
