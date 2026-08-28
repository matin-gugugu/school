# Redis 实时请求进度

## 1. 为什么需要第二套进度

MySQL 中的 success_count/failed_count 主要在 Shard 汇总时更新。一个大 Shard 可能运行很久，如果只看 MySQL，用户会长时间看到计数不变。

因此系统增加 Redis 请求级实时进度：每条请求完成即记录，查询 API 对非终态 Task 用 Redis snapshot 覆盖 MySQL 的 RequestCounts。

```text
执行请求 → Redis实时计数 → 查询API展示
Shard完成 → OSS元数据汇总 → MySQL持久计数
Task终态 → 删除实时结构 → 查询API只用MySQL
```

Redis 是实时视图，不是最终事实源；终态计数仍由 OSS Shard Metadata 汇总后写 MySQL。

## 2. Redis Key

每个 Task 使用四类 key：

```text
batch_progress:{taskID}:done      Set：已经结束的 requestID
batch_progress:{taskID}:failed    Set：最终失败的 requestID
batch_progress:{taskID}:snapshot  Hash：completed/failed/updated_at
batch_progress:{taskID}:closed    String：终态关闭标记
```

TTL 都是 7 天，单次 Redis 操作超时 500ms。

## 3. 原子更新算法

请求结束时执行 Lua：

```text
if closed exists:
    ignore late report

SADD done requestID
if failed:
    SADD failed requestID
else:
    SREM failed requestID

doneCount = SCARD(done)
failedCount = SCARD(failed)
completed = doneCount - failedCount
HSET snapshot completed failed updated_at
刷新TTL
```

Lua 保证去重、失败集合修正和 snapshot 更新原子完成。

## 4. 为什么用 Set 而不是 INCR

系统有 Shard 重试和升级孤儿恢复，语义是 at-least-once。同一请求可能多次完成。如果直接 INCR，会重复计数；用稳定 requestID 做 SADD，重复上报不会增加基数。

当同一 ID 先失败后重试成功时，`SREM failed` 可以把它修正为 completed。这要求 requestID 在所有 attempt 和 Shard 恢复中稳定。

请求响应没有 ID 时回退为：

```text
shard:{shardIndex}:line:{lineIndex}
```

该值也是确定性的，可覆盖重执行场景。

## 5. 上报时机

`funcCall` 使用 defer 上报最终 BatchResponse。以下情况有特殊处理：

- Response 为空：不上报；
- 真正确认 Task expired：关闭本次 report；
- 取消并成功转 stopped：关闭本次 report；
- 普通请求成功或失败：正常上报；
- Redis 超时/错误：只记录 warning，不让推理请求失败。

这是可观测性 fail-open：进度偶尔落后不应反过来破坏任务执行。

## 6. 查询路径

### 6.1 单 Task

查询 MySQL Task 后，若不是 completed/failed/stopped/expired/deleted，再读 Redis snapshot 覆盖：

```text
RequestCounts.Completed
RequestCounts.Failed
```

### 6.2 多 Task

批量查询最多 20 个 Task，并用 Redis Pipeline 一次读取多个 Hash，避免 N 次网络往返。

Redis 查询失败时保留 MySQL 值并记录 warning，不导致 API 失败。

## 7. 终态关闭协议

Task 进入终态后，Store 异步执行 Lua：

1. 写 `closed=1`，TTL 7 天；
2. 删除 done、failed、snapshot。

顺序非常重要：closed 阻止仍在飞行中的请求重新创建已删除的进度结构。终态查询不再应用 Redis snapshot，展示 MySQL 最终计数。

## 8. 一致性边界

- Redis 记录成功、进程随后崩溃、Shard Metadata 未完成：实时数可能短暂领先。
- Redis 上报失败：实时数可能落后，Shard 完成后 MySQL会纠正。
- 终态清理是异步的，但 API 已按状态忽略 Redis。
- 7 天内 closed 防晚到写；更晚的极端迟到写理论上可重建 key，但正常请求生命周期不应超过该窗口。

## 9. 空间复杂度

两个 Set 需要保存 requestID，空间复杂度为 O(任务请求数)。大任务百万级请求时要评估：

```text
内存 ≈ request count × (ID长度 + Redis Set对象开销)
```

若内存成为瓶颈，可以考虑位图/分片计数，但必须继续解决 at-least-once 去重和失败转成功的问题。

## 10. 面试表达

> MySQL 的进度按 Shard 落库，粒度太粗，所以我会把 Redis 定位成非终态的实时物化视图。每个完成请求用稳定 ID 写 Set，Lua 原子计算 snapshot，天然抵抗 Shard 重执行；Task 终态先写 closed 再删除集合，阻止晚到请求把进度重新建出来。查询失败时回退 MySQL，不影响主链路。

## 11. 源码定位

- `services/redis/batch_progress.go`
- `scheduler/executor/executor.go: reportBatchProgress`
- `internal/service/apiserver/api_batch/api_batch.go: applyRealtimeRequestCounts`
- `internal/client/store/msql/store_batch_task.go: clearTerminalBatchProgressCache`

