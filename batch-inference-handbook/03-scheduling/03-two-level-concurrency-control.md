# 两级并发控制

## 1. 为什么需要两级并发

如果只限制请求 goroutine：

- 可能同时打开过多 Shard 文件；
- 每个 Shard 都持有结果数组和 Buffer；
- OSS 并发与进度汇总压力不可控。

如果只限制 Shard 数：

- 单 Shard 内数千条请求可能同时打向 Gateway；
- 无法精细匹配模型容量。

因此采用：

```text
第一级：模型 Shard 并发
第二级：模型 Request 并发
```

## 2. 第一级：Shard 并发

配置：

```yaml
model_config:
  models:
    model-a:
      max_execute_shard: 5
```

运行时每模型维护原子 Counter：

```text
领取前：检查 running + selected < max
执行 goroutine 内：IncNumWithMaxNum(max)
执行结束：DecNumOnZero()
```

两次检查分别处理：

- Starter 批量选择阶段避免明显超领；
- 多轮 Timer 并发时由原子 Counter 做最终保护。

## 3. 第二级：Request 并发

配置：

```yaml
model_config:
  models:
    model-a:
      max_execute_goroutine: 100
```

每个模型创建一个阻塞式 ants Pool：

```text
poolMap[model] = ants.NewPool(maxExecuteGoroutine)
```

Shard 解析出全部请求后逐条：

```text
WaitGroup.Add(1)
pool.Submit(funcCall)
```

当 Pool 满时 Submit 阻塞，形成模型级背压。多个 Shard 共用同一个模型 Pool，因此并发不会按 Shard 倍增。

## 4. ConcurrencyController

```go
type ConcurrencyController struct {
    modelNameList []string
    poolMap       map[string]*WorkPool
    shardMap      map[string]int
}
```

职责：

- 保存当前 KConf 模型列表；
- 查找或创建模型 Worker Pool；
- 返回模型 Shard 上限；
- 动态 Tune 已有 Worker Pool；
- 输出每模型 Running Worker 数。

## 5. 动态配置生效

KConf 更新后：

```text
ModelExecuteWatcher.OnChange
→ 替换 GlobalModelExecuteConfig
→ 周期任务 UpdateConcurrencyController(models)
→ 更新 modelNameList
→ pool.CompareAndChangeCap(newWorkerNum)
→ shardMap[model] = newShardNum
```

ants `Tune` 不会中断已经运行的 goroutine；缩容主要影响后续 Submit。

## 6. 默认值

代码级默认：

```text
default max worker per model = 10
default max shard per model  = 5
```

全局 `WorkerConfig.MaxConcurrency` 属于兼容/旧配置路径，主要模型控制来自 KConf。

## 7. 配置为 0 的真实语义

`Risk`：模型配置 API 文档把 `max_execute_goroutine=0` 描述为暂停执行，但当前 `GetMaxModelConfigMap` 会把 `<=0` 转成默认 10；Shard `<=0` 转成默认 5。`UpdateConcurrencyController` 对已有 Shard 配置也只在 `inputNum > 0` 时更新。

因此当前快照中“设置 0 暂停模型”并不可靠，文档语义与运行实现不一致。真正停流应：

- 在调度候选层禁用模型；或
- 让 Pool/Shard Controller 显式支持 0；
- 同时处理已领取 Shard 和在途请求。

## 8. 容量口径

`max_execute_goroutine` 是单 Batch Inference 实例的模型请求并发，不是集群总并发。

```text
集群理论请求并发
≈ 单实例 max_execute_goroutine × Batch 实例数
```

自动调谐先计算模型集群 Ready Capacity，再除以 `service_instance_num` 得到单实例上限。

配置中的实例数必须与实际部署副本接近，否则：

- 配小：每实例目标偏高，集群过载；
- 配大：每实例目标偏低，资源利用率不足。

## 9. 内存和吞吐关系

近似关系：

```text
模型吞吐 ≈ requestConcurrency / averageRequestLatency
```

但并发提高还会影响：

- KV Cache 占用；
- waiting queue；
- 单请求延迟；
- 429/529/5xx；
- Batch 实例本身的 goroutine、结果数组和网络连接。

因此不能仅按 Ready 副本线性放大，并发自动调谐需要成功率和 queue ratio 反馈。

## 10. 线程安全边界

`Risk`：Controller 的 `modelNameList`、`poolMap`、`shardMap` 在周期更新和 Scheduler 读取间没有显式 Mutex。ants Pool 自身支持 Tune，但外层 map 并发读写可能产生 data race。可通过：

- RWMutex；
- immutable snapshot + atomic.Value；
- 单线程配置事件循环；

实现安全热更新。

## 11. 面试表达

> 系统用两级并发控制拆开“数据执行单元”和“模型请求容量”：max_execute_shard 限制同时活跃的 Shard 和 OSS/内存压力；max_execute_goroutine 对应每模型共享 Worker Pool，限制真正打到 Gateway 的请求数。所有同模型 Shard 共享请求池，KConf 变更后通过 ants Tune 动态生效。

## 12. 源码定位

- `scheduler/executor/concurrency_controler.go`
- `scheduler/statistics/single_model_counter.go`
- `pkg/utils/pool.go`
- `scheduler/executor/starter.go: meetMaxExecuteShardNum`
- `scheduler/executor/executor.go: processShardData`
