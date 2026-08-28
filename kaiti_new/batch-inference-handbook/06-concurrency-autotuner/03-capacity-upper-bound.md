# Ready Capacity 与并发上界

## 1. 配置模型

每个开启调谐的模型配置：

```yaml
max_execute_goroutine: 100
auto_reconcile_enabled: true
per_instance_concurrency:
  baseline_concurrency: 80
  ksn_concurrency:
    ksn-a: 80
    ksn-b: 120
```

- baseline_concurrency：基准卡型的单副本并发；
- ksn_concurrency：各 KSN 单副本并发；
- max_execute_goroutine：每个 batch-inference 服务实例的模型 WorkPool cap。

## 2. 卡型归一

不同 GPU 卡型通过比例表换算：

```text
perReplicaCapacity(KSN)
  = floor(baselineConcurrency × cardTypeRatio[deviceType])
```

示例比例：X40=1.0、X50=1.5、X60=2.0。若 baseline=80：

```text
X40 → 80
X50 → 120
X60 → 160
```

Go 转 int64 会向下截断。baseline、卡型、比例缺失或非正时，已配置 KSN 回退到原 `ksn_concurrency`；新发现 KSN 则无法纳入。

## 3. KSN Ready Capacity

```text
readyCapacity(KSN)
  = readyReplicas(KSN) × perReplicaCapacity(KSN)
```

模型集群原始容量：

```text
totalReadyCapacity = Σ readyCapacity(KSN)
```

只统计 Runtime 有效、满足 public/private pool 规则的 Ready KSN。

## 4. 单实例上界

```text
clusterTarget = totalReadyCapacity × safetyRatio

upperBoundPerBatchInstance
  = ceil(clusterTarget / serviceInstanceNum)

upperBound
  = clamp(upperBoundPerBatchInstance, goroutineMin, goroutineMax)
```

当前默认：

```text
safetyRatio = 1.0
goroutineMin = 1
goroutineMax = 全局 goroutine_max（无配置时200）
```

`serviceInstanceNum` 是静态配置，不是实时 Ready 的 batch-inference Pod 数；配置不准会导致集群总并发偏高或偏低。

## 5. 计算示例

假设：

| KSN | 卡型 | Ready | 单副本能力 | Capacity |
| --- | --- | ---: | ---: | ---: |
| A | X40 | 2 | 80 | 160 |
| B | X60 | 3 | 160 | 480 |

```text
totalReadyCapacity = 160 + 480 = 640
serviceInstanceNum = 2
upperBound = ceil(640 / 2) = 320
```

若 `goroutine_max=200`，最终每实例上界为 200，集群 Batch 请求并发约 400。

## 6. 原始上界与有效上界

控制器先对所有匹配 KSN 算 `raw_upper_bound`。但某些 KSN 可能缺成功率或队列指标，无法安全参与反馈决策；这些 KSN 会连同其 Ready Capacity 一起排除，再计算：

```text
effectiveUpperBound
  = upperBound(Σ effectiveKSNReadyCapacity)
```

这是一个保守原则：没有观测能力的容量不参与自动扩并发。日志同时打印 raw/effective upper bound 和 excluded capacity，便于判断是资源少还是指标缺失导致降上界。

## 7. KSN 配置自校准

对于 KConf 中已有 KSN，如果根据 baseline×card ratio 推导的值不同，Reconciler 会同时更新 `ksn_concurrency`。这样卡型能力表成为统一基线，减少逐 KSN 手工配置漂移。

运行时新发现但 KConf 未列出的 KSN 当前只用于上界计算，日志明确标记 `upper bound only`，不会自动补进 KSNConcurrency map。

## 8. Ready 副本变化

- 扩容：上界升高，反馈探测仍按步长逐渐增并发；
- 缩容：新上界降低，`clamp` 会立即把目标压到上界以内；
- 无匹配 KSN：跳过该模型配置更新；
- total capacity<=0：上界函数回退 goroutineMin，但通常前面的 matched/ready 过滤会先跳过。

这种“升慢降快”符合容量控制的安全方向。

## 9. 安全系数的现实含义

代码默认 1.0，注释建议 0.7~0.8。即使单副本基线来自压测，生产仍可能因长上下文、输出长度分布和其他流量产生偏差。

可以考虑：

```text
effectiveSafety = baseSafety × workloadCorrection × SLOCorrection
```

或者保留 1.0 的硬理论上界，由反馈探测永远不直接跳满；当前初始探索和步长已经部分承担这一作用。

## 10. KV Cache 的联系

并发太低时，同时在途序列少，KV Cache 利用率低；提高并发可以填充 batch 和 cache。但并发超过可承载点后，排队和显存压力会上升，成功率下降。

因此 Ready Capacity 不是直接优化 KV Cache 的指标，而是提供安全搜索空间；成功率与队列负载负责判断是否接近拐点。KV Cache 利用率适合作为灰度效果指标和未来第三反馈信号。

## 11. 风险与改进

- `service_instance_num<=0` 时 CeilDiv 返回 0，最终被 min clamp 为1并记录错误；应启动时强校验。
- 卡型比例是线性模型，但推理能力可能与模型、序列长度非线性相关；应按模型族/卡型维护 profile。
- 单副本能力不区分输入输出 token 分布；可用 token/s、prefill/decode 分段建模。
- ReadyReplicas 只说明 Kubernetes readiness，不保证持续健康，需反馈信号二次约束。

## 12. 面试表达

> 上界不是直接拿副本数乘固定值。我先用 baseline concurrency 和 GPU 卡型比例推导每个 KSN 的单副本能力，再乘 ReadyReplicas 求集群容量，按 batch 服务实例数分摊并做 min/max 限制。缺少反馈指标的 KSN 连容量也排除，用有效容量重算上界，避免拿不可观测资源冒险扩并发。

## 13. 源码定位

- `internal/service/modelconcurrency/model_capacity_deriver.go`
- `internal/service/modelconcurrency/model_concurrency_policy.go`
- `internal/service/modelconcurrency/model_concurrency_reconciler.go`
- `internal/config/model_config.go`
- `internal/isvc/`

