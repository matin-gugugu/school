# Shard 领取与调度

## 1. 调度入口

Service 按 `scheduler_interval` 周期调用：

```text
Scheduler.ScheduleExecutor(ProcessQueueType, ProcessType)
```

一次完整调度分三段：

```text
StarterExec → Execute → EnderExec
```

| 阶段 | 作用 |
| --- | --- |
| Starter | 从 Redis 找到本轮可执行 Shard，构建执行单元 |
| Execute | 并行执行所有 Shard |
| Ender | 将 Shard 级失败项加入 failed queue |

## 2. Starter 调度算法

简化伪代码：

```text
models = KConf configured model list
selected = map[model][]shard

repeat at most 5 rounds:
    before = selected.total

    for model in models:
        if currentRunningShard(model) + selected(model)
             >= modelMaxExecuteShard:
            continue

        if selected(model) >= maxExecuteShardNumPerRound:
            continue

        shard = getShardFromQueue(model, queueType)
        if shard exists:
            selected.add(model, shard)

    if selected.total == before:
        break

parse each selected queue value into ShardExecuteUnit
return units
```

### 2.1 为什么最多五轮

每一轮对每个模型最多领取一个 Shard，最多五轮让多个模型近似轮询，避免单模型一次吞掉所有本轮额度。实际公平性仍受 KConf map 遍历顺序和各模型队列状态影响。

### 2.2 两个 Shard 上限

- `max_execute_shard_num`：单个 Scheduler 本轮从某模型新增的步长上限；
- `model.max_execute_shard`：模型在当前服务实例内同时活跃的 Shard 上限。

模型上限计算：

```text
runningShardCounter(model) + selectedThisRound(model)
    <= modelMaxExecuteShard
```

## 3. 不同队列的领取方式

### 3.1 Process 调度

```text
pending --Lua atomic move--> process
同时创建 upgrade heartbeat
```

### 3.2 Failed 调度

```text
LPOP failed
→ 检查 joinTimestamp
→ 未到 retry interval：重新 RPUSH failed
→ 到达 retry interval：执行
→ 超过 max retry interval：丢弃
```

### 3.3 PendingQueueType

代码保留直接从 pending `LPOP` 的调度方式，但对应 Timer 在当前 `Service.Start()` 被注释，主链路不使用。

## 4. ShardExecuteUnit

Starter 把字符串转换为：

```go
type ShardExecuteUnit struct {
    modelName        string
    queueKey         string
    shardDatasetKey  string
    shardMetadataKey string
    shardOutputKey   string
    joinTimestamp    int64
    err              error
}
```

Executor 不需要查询 Shard 数据库表；所有执行输入都由该单元和 OSS Metadata 提供。

## 5. Execute 调度

对每个 ShardExecuteUnit 启动 goroutine：

```text
发送 running notice（task 级 once）
启动 upgrade heartbeat
等待获取模型 Shard Counter 配额
processShard(unit)
记录 success/failed unit
释放 Shard Counter
从 process queue LREM
停止 heartbeat
```

本轮 Scheduler 会 `WaitGroup.Wait()` 等待所有已选 Shard 结束，之后才执行 Ender。由于外层 Timer 每个周期又启动新 goroutine，不同调度轮次仍可能并行，真正的 Shard 上限由共享 Counter 控制。

## 6. Ender

Ender 校验：

```text
needExecuteUnits == successUnits + failedUnits
```

失败项：

```text
if now - joinTimestamp <= failedMaxRetryInterval:
    RPUSH model_failed_queue
else:
    记录最终失败日志，不再入队
```

## 7. 多实例并发

### 7.1 Claim 是全局的

pending → process 使用 Redis 原子脚本，所以跨实例不会同时 claim 同一个 pending 元素。

### 7.2 Counter 是进程内的

Shard Counter 和 Worker Pool 都在单个服务进程内。因此：

```text
全局最大 Shard 数
≈ 单实例 max_execute_shard × 服务实例数
```

它不是 Redis 全局并发令牌。

自动调谐计算 Request 并发上界时会除以 `service_instance_num`，用于把集群容量分摊到每个 Batch 实例；Shard 并发没有同样的自动分摊公式。

## 8. 空队列行为

Lua 没取到元素时返回 nil，封装层把它转换为 `no elements in source queue` 错误；Starter 忽略错误并继续其他模型。空队列是正常状态，不应作为告警错误。

## 9. 公平性与优先级

当前没有任务级优先级、租户权重或 Deadline 排序：

- 同一模型内是 Redis List FIFO；
- 不同模型之间近似每轮各取一个；
- 模型遍历顺序来自 Go map，不稳定；
- completion window 只用于超时，不参与调度排序。

若需要 EDF、行业优先级或资源池独占，需要在 Starter claim 前增加显式候选过滤/排序，不能依赖 map 顺序。

## 10. 面试问题

### 为什么 Scheduler 不做全局 Leader？

普通消费只需要每个 Shard 的原子 claim，多实例共同调度能直接扩展吞吐。只有更新 KConf、扫描账号冻结等全局单写任务才需要周期锁。

### 为什么有本轮步长和运行上限两个配置？

运行上限控制稳定态资源，单轮步长控制突发领取速度，避免一个 Scheduler Tick 瞬间将大量 Shard 移入 process。

## 11. 源码定位

- `internal/service/service.go` Scheduler Timer
- `scheduler/scheduler.go: ScheduleExecutor`
- `scheduler/executor/starter.go`
- `scheduler/executor/execute_unit.go`
- `scheduler/executor/ender.go`
- `scheduler/statistics`
