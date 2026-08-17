# 核心经历二：模型并发自动探测

## 1. STAR 主回答

### Situation

离线模型并发原先依赖人工静态配置。配置偏低时GPU/KV Cache吃不满，偏高时高峰出现429/529/5xx、排队和重试放大；副本数、卡型和请求长度变化使一个固定值很快失效。

### Task

做一个多模型、多KSN、多Batch服务副本下可运行的闭环控制器：能根据实时容量给出安全上界，在上界内自动探索吞吐，过载时快速回退，并可灰度、可解释、可人工关闭。

### Action

1. 容量建模：`ReadyReplicas × baselineConcurrency × cardTypeRatio` 求每KSN容量，汇总后按Batch实例数分摊并clamp；
2. 信号采集：Gateway perflog筛选Sheddable离线流量，2xx成功，429/5xx失败，30秒桶、10分钟窗口、最小100请求；
3. 队列信号：Scaler `waiting/running` 表示排队压力；Gateway样本不足回退Scaler成功率；
4. 决策策略：成功率0.990/0.995和队列0.4/1.0形成迟滞，fast/slow/hold/rollback分别+5%/+2%/0/-10%上界；
5. 多KSN：缺指标KSN及其容量排除，有效KSN按rollback>hold>slow>fast聚合；
6. 多实例：Redis全局采样锁和Reconcile锁，窗口/last result保存在Redis；
7. 执行闭环：统一写KConf，Watcher传播，定时热调模型WorkPool cap；
8. 灰度：shadow只决策不写，再单核心模型、高峰时段逐步放量，观察失败率、延迟、队列、KV Cache、完成率。

### Result

`Experience Result`：核心离线模型高峰期容量相关失败率12.1%→1.8%，KV Cache平均利用率37%→71%。

## 2. 控制公式

```text
perReplica = floor(baseline × cardRatio)
ksnCapacity = readyReplicas × perReplica
upperBound = clamp(ceil(ΣeffectiveCapacity × safety / batchInstances), min, max)

fastStep = ceil(upperBound × 5%)
slowStep = ceil(upperBound × 2%)
rollbackStep = ceil(upperBound × 10%)
```

## 3. 为什么两个信号

- 只看成功率：队列已积压但尚未失败时反应太慢；
- 只看队列：短请求/路由变化可能让ratio波动，无法体现真实SLO；
- 两个都好才快探，任一坏立即退，兼顾早期压力与最终结果。

Ready容量不是第三个反馈信号，而是硬搜索边界。

## 4. 为什么不用load1

load1是通用系统指标，不直接反映推理Engine的KV Cache、prefill/decode和请求排队。waiting/running更接近容量饱和，Gateway容量错误更接近用户SLO。KV Cache当前作为灰度效果指标，未来可作为输入。

## 5. 为什么能失败下降又利用率上升

闭环不是“统一降并发”或“统一加并发”：

- 健康低压时逐步加，提升cache/吞吐；
- 高峰过载时更大步回退，降低容量错误；
- 副本缩容时硬上界立即收缩；
- 迟滞和窗口避免来回震荡。

效果来自时间维度上更贴近实时容量。

## 6. 多KSN难点

一个模型可能跨不同卡型和资源池：

- 卡型用ratio归一单副本能力；
- 每KSN独立采信号；
- 缺指标容量不能支撑自动扩容；
- 任一有效KSN bad对共享总并发有veto；
- private模型允许非offline pool，public只用离线池。

更高级方案是每KSN独立预算并调Gateway路由权重，但复杂度更高。

## 7. 高频追问

### 阈值怎么定？

先依据SLO和历史失败分布设初值，再用历史窗口回放看误调/收敛速度，shadow验证decision，灰度调步长。当前默认坏<99.0%、好>99.5%，中间为迟滞区。

### 为什么10分钟窗口、5分钟调？

要达到最小请求量并过滤短抖动，又能在高峰内多次反应。共享历史样本稳定但有滞后，应结合模型请求时长和流量验证。

### 样本缺失怎么办？

Gateway不足100回退Scaler；任何必要信号仍缺则排除该KSN及容量；全部缺时保持当前并发且不覆盖上次有效状态。

### 如何防多实例重复写？

采样和Reconcile各有Redis全局锁；KConf统一批量写。更严格可加fencing/revision CAS，因为TTL锁超时后理论上仍可重入。

### 如何防震荡？

good/bad迟滞区、10分钟窗口、5分钟周期、升小步降大步、容量上界和最小样本。可再加连续N轮、冷却期和emergency breaker。

### 当前算法像什么？

是带硬容量上界和双信号迟滞的AIMD变体：固定比例上界的加性探测、较大步长下降，强调可解释和安全。

### 失败率口径？

控制器只统计Sheddable离线请求，2xx成功，429/5xx失败，排除业务4xx。项目看板口径需按真实历史定义说明，不把未知口径混为一谈。

### KV Cache是不是输入？

当前不是，是灰度效果指标。说成“基于KV Cache调节”不准确。

## 8. 代码级调用链

```text
Service.Start
→ StartRequestSuccessCollectorFromGlobal
→ SampleAutoTunerMetricsOnce
→ Scaler.SelectISVCMetrics
→ Redis ZSET window
→ ReconcileOnce
→ FetchRuntimeInfoMap/DeriveKSNConcurrency
→ EvaluateConcurrencySignal
→ selectAutoTuneKSNs/Aggregate/Apply
→ ApplyModelConfigUpdates
→ KConf Watcher
→ ConcurrencyController.Update
→ WorkPool.CompareAndChangeCap
```

