# 交付语义、幂等与一致性

## 1. 总体结论

当前系统的核心语义是：

```text
Shard 执行：at-least-once
Gateway 调用：可能重复
OSS 确定性对象：last-write-wins
Redis 实时进度：按requestID幂等
Kafka逐请求结果：可能重复或丢失
Task状态：条件更新为主，但路径不完全统一
```

它追求“实例故障后不丢任务”，没有提供端到端 exactly-once。

## 2. 各阶段语义

| 阶段 | 机制 | 故障后结果 |
| --- | --- | --- |
| API→TaskCreator | DB 后本地 goroutine | 进程崩溃可能 Task 留 init |
| 输入→Shard OSS | 确定性 key、整对象覆盖 | 重试可覆盖，但部分上传/入队可残留 |
| pending→process | Redis Lua 原子移动 | 元素不在两队列间丢失 |
| Shard 执行 | process记录+heartbeat恢复 | 宕机后可重做整个 Shard |
| Gateway 请求 | 稳定 request ID，但无已知结果事务 | 响应丢失时可能重复推理 |
| 实时进度 | requestID Set+Lua | 重复完成不重复计数 |
| Shard结果 | 确定性 OSS key | 重做覆盖同对象 |
| Kafka结果 | 异步 producer retry | 崩溃可丢、恢复可重复 |
| 最终Merge | 确定性 key+Multipart metadata确认 | 可重做，跨实例会重复 IO |

## 3. 幂等键

| 对象 | 幂等标识 |
| --- | --- |
| Task | `bt-{uuid}` |
| Request | 分片时生成的 `batch-{uuid}` |
| 无响应ID进度 | `shard:{index}:line:{index}` |
| Shard输入/Metadata/输出 | `(taskID, shardIndex)`确定性OSS路径 |
| Running/Schedule通知 | Task ID 的 ExecuteOnce key |
| 实时进度 | `(taskID, requestID)` Redis Set |
| AutoTuner周期 | Redis全局定时器锁 |

这些键把重复执行的“状态副作用”部分收敛，但不能撤销已经发生的模型计算/计费。

## 4. exactly-once effect 需要什么

若 Gateway 支持 request ID 幂等：

```text
第一次请求成功但响应丢失
  → 重试携带同requestID
  → Gateway返回原结果/拒绝重复计费
```

否则只能做到 at-least-once invocation。要提升为 exactly-once effect，需要：

- Gateway 维护 requestID→结果/计费记录；或
- Batch 平台在调用前写 durable intent、调用后写 result，但仍需下游幂等解决“调用成功、结果未写”的不确定窗口。

分布式事务不能凭本地锁消除这个窗口。

## 5. Task 状态一致性

理想状态更新：

```sql
UPDATE task SET status=:next
WHERE id=:id AND status=:expected
```

并检查 `RowsAffected==1`。当前事件更新虽然带旧状态条件，但：

- 读取 source Task 使用 DB 主连接而非同一 tx；
- Updates 只检查 Error，不可靠检查 RowsAffected；
- `FAIL` 与 `RUN_COMPLETE` 可从任意状态生成目标状态；
- 取消路径直接 Updates，不统一走事件状态机。

因此日志中的“更新成功”不总等于状态确实发生转换。

## 6. OSS Metadata 一致性

Task/Shard Metadata 是整对象覆盖，没有版本号、ETag CAS 或单调状态校验。两个执行 attempt 并发时可能：

```text
新attempt写 completed
旧attempt稍后写 failed
```

最终对象取决于最后写入者。确定性 Key 解决对象数量膨胀，不等于解决并发写顺序。

建议 Metadata 带 `attempt`、`revision`，写入时 CAS；Reducer 只接受更高 attempt 或合法单调状态。

## 7. Kafka 与 Outbox

结果消息在保存 Shard Metadata 后异步发送，不和 OSS/MySQL 构成事务：

- goroutine 未开始前进程退出：丢失；
- 部分消息发送后进程退出：恢复后重复部分；
- Kafka 5次失败：只告警，Task 仍可 completed。

可靠方案是 durable outbox/Shard manifest，Dispatcher 有 delivery cursor、attempt 和对账。

## 8. 终态不可逆原则

应明确：completed/failed/stopped/expired/deleted 都是终态，任何迟到 Shard 不应改变终态或重建进度。当前 Redis closed 已实现这一原则；DB 状态机的无条件 FAIL/RUN_COMPLETE 仍可能破坏它。

建议所有终态事件使用优先级和 expected states：

```text
RUN_COMPLETE: only running/merging
FAIL: only init/pending/running/merging
STOP_COMPLETE: only stopping
TIMEOUT: only init/pending/running
```

## 9. 面试表达

> 系统提供的是 Shard 级 at-least-once：pending到process用Lua原子claim，实例退出后heartbeat过期会重做。稳定requestID、Redis Set和确定性OSS Key让状态副作用幂等，但Gateway调用与Kafka交付仍可能重复或丢失，所以不能宣称端到端exactly-once。真正的exactly-once effect要靠Gateway幂等和durable outbox。

## 10. 源码定位

- `scheduler/queue/queue_controller.go`
- `scheduler/executor/upgrade/handler.go`
- `services/redis/batch_progress.go`
- `internal/client/store/msql/store_batch_task.go`
- `scheduler/executor/executor.go`
- `services/mq/producer.go`

