# KConf 写回与 WorkPool 热更新

## 1. 控制输出是什么

AutoTuner 最终修改模型配置中的：

```text
max_execute_goroutine
```

容量推导发现已配置 KSN 的 per-replica 值变化时，还会更新：

```text
per_instance_concurrency.ksn_concurrency
```

它不自动修改 `max_execute_shard`；Shard 并发仍是独立的内存/调度保护参数。

## 2. 统一写入口

Reconciler 构造 `ModelConfigUpdateRequest`：

```text
source   = reconciler
operator = model-concurrency-reconciler
reason   = target、decision、upper bound等
```

与手动 API 一样进入 `ApplyModelConfigUpdates`：

1. 校验模型名和字段；
2. 克隆当前配置为 working copy；
3. 批量应用所有模型更新；
4. 一次写回 KConf；
5. 记录更新指标与审计日志。

批量写失败则本轮所有模型都不保存 AutoTuner last result。

## 3. KConf Watcher

每个 Batch 服务实例注册模型配置 Watcher。KConf 变化后：

- 解析新 `ModelExecuteConfig`；
- 对比并记录模型新增、删除、goroutine/shard 变化；
- 替换进程内全局配置指针。

Watcher 自身不直接改 WorkPool。服务还有周期任务按 `work_pool_cap_check_interval` 读取最新全局配置并调用：

```text
ExecuteCoreController.UpdateConcurrencyController(models)
```

所以控制生效延迟近似为：

```text
KConf传播延迟 + WorkPool检查间隔
```

## 4. WorkPool 如何变更

模型已存在 Pool：

```text
pool.CompareAndChangeCap(newCap)
```

模型首次出现则创建新 Pool。新请求会受新 cap 控制；已经 Running 的 goroutine不会被强杀，缩容通常是让并发随完成逐步降到新上限。

模型 Shard limit 也在同一周期更新到 Controller，并同步初始化/更新进程内 Shard Counter。

## 5. Last Result 状态

每个模型保存最近一轮有效结果：

```text
decision / reason
current goroutine
candidate target
previous upper bound
current upper bound
write enabled
timestamp
```

Redis Key：

```text
batch-inference:auto-tuner:last:{model}
```

TTL：

```text
metricsWindow + 2 × tuneInterval + 60s
```

默认 600 + 2×300 + 60 = 1260 秒（21分钟）。它用于识别是否首次探索以及记录决策连续性，不是永久审计库。

## 6. 写入与状态保存顺序

```text
计算 candidate
  → 调用 KConf Update
  → 成功：保存 last result
  → 失败：不保存
```

如果 target 与当前相同但产生了有效决策，代码仍可保存 last result而不写 KConf。若所有 KSN 缺指标，`PersistLastResult=false`，保留上一轮有效状态。

这个顺序避免控制器在重启后误以为某个目标已经应用。

## 7. 可观测与审计

日志/指标覆盖：

- 拉取 ISVC 失败；
- raw/effective capacity 和 KSN detail；
- 每 KSN 平均信号、级别与来源；
- excluded KSN 和原因；
- current/target/upper bound/previous bound；
- KConf 写成功/失败；
- 模型 goroutine/shard 前后值与 source；
- 设置 0 的告警。

建议把每轮决策落结构化时序表，保留灰度回放所需的 input、decision、output、config revision，而不只依赖短 TTL Redis 和文本日志。

## 8. 0 值语义不一致

配置更新 API 允许把 goroutine/shard 设为 0，并告警其可能导致队列积压。但 Runtime Controller 的 `GetMaxModelConfigMap` 会把 `<=0` 转成默认：

```text
goroutine → 10
shard → 5
```

因此“0 表示暂停”在当前运行时不成立。控制面、配置说明和执行面必须统一：

- 若 0=暂停，WorkPool/调度器必须真正拒绝新任务；
- 若 0=自动/默认，API 和告警应这样描述；
- 更清晰的是独立 `enabled/paused` 字段。

## 9. 并发安全风险

Watcher 替换全局配置指针、WorkPool 定时器读取配置；`ConcurrencyController` 的 poolMap/shardMap 也由定时器更新并被 Scheduler/Executor 并发读取，当前 Controller map 没有显式 mutex。

Go map 读写并发可能 data race 甚至 panic。建议：

- 配置使用 `atomic.Pointer` 或 RWMutex；
- Controller 使用不可变 snapshot 原子替换；
- WorkPool 对象保留，map 结构 copy-on-write；
- CI 执行 `go test -race`。

## 10. 人工回滚与熔断

闭环系统需要明确运维开关：

- 全局 `auto_tuner_enabled=false`：停止反馈探测；
- 单模型 `auto_reconcile_enabled=false`：冻结该模型自动写；
- 手动设置保守 goroutine；
- Gateway 成功率 Collector 可独立关闭并回退 Scaler；
- 变更审计应能找回上一 revision。

关闭 AutoTuner 后，Ready Capacity Reconciler 是否仍写目标取决于 `auto_reconcile_enabled`：当前主 Reconciler 仍会按物理容量计算并写并发，只是不做反馈探测。若要完全冻结自动更新，需要关闭单模型 auto_reconcile。

## 11. 面试表达

> 决策不是只打日志，而是批量写回 KConf；所有实例通过 Watcher拿到新配置，再由周期任务热调整模型 WorkPool cap，形成执行反馈。手动API和自动控制共用一套校验、审计和写入口。last result 只在 KConf 成功后保存，避免状态与真实配置分叉。我们还需要特别防止0值语义不一致和Controller map并发读写问题。

## 12. 源码定位

- `internal/service/apiserver/model_config_service.go`
- `pkg/kconf/model/model_execute_watcher.go`
- `internal/config/model_config.go`
- `scheduler/executor/concurrency_controler.go`
- `internal/service/service.go`
- `internal/service/modelconcurrency/model_concurrency_autotuner_state.go`

