# 成功率、队列负载与滑动窗口

## 1. 两类主要反馈信号

| 信号 | 含义 | 主要来源 |
| --- | --- | --- |
| request success rate | 当前并发是否产生容量相关失败 | Gateway perflog Kafka，Scaler 兜底 |
| queue load ratio | 排队压力相对执行中请求的大小 | Scaler `queue.waiting/queue.running` |

代码也能读取 load1，但 AutoTuner 明确不使用它做决策。GPU 模型服务中系统 load 不一定能直接代表 KV Cache 与请求队列饱和。

## 2. Gateway 成功率采集

独立 Kafka Consumer 消费 Gateway protobuf perflog，只保留：

```text
metric = wanqing.intelligent.router.request_cost
traffic = offline/Sheddable
model service name 可识别
HTTP status 可识别
```

Batch 请求固定携带 `X-Ks-Wq-Request-Schedule-Priority: Sheddable`，因此可以从混合 Gateway 日志中筛出离线流量，避免在线请求污染控制信号。

## 3. 成功和失败口径

```text
2xx       → success +1, total +1
429       → success +0, total +1
5xx       → success +0, total +1
其他状态  → 不进入这个成功率
```

因此它更准确地表示“容量/服务端健康成功率”，不是所有 API 请求的业务成功率。400/401 等客户端错误被排除，避免坏数据或鉴权问题触发错误降容。

529 属于 5xx，自动包含在失败口径中，和 Executor 的容量重试分类一致。

## 4. 时间桶

默认每 30 秒一个 Redis Hash：

```text
batch-inference:gateway-request-success:v3:{bucket}:{encodedModel}
  success = ...
  total   = ...
```

使用 `HINCRBY` 聚合 Kafka 样本，TTL 至少 30 分钟。查询 10 分钟窗口时只读取已经结束的桶，排除当前未完整桶，避免分母尚未到齐产生抖动。

默认最小样本数是 100。窗口总量不足时不使用 Gateway 成功率，回退到 Scaler 成功率。

## 5. Scaler 成功率选择

Scaler View 同时可能有：

```text
engine.http.success_rate
gateway.success_rate
```

采样时优先 engine，其次 gateway，并记录 source。到决策阶段，如果独立 Gateway Collector 在窗口内达到最小样本数，则覆盖 Scaler 成功率；否则保留 Scaler 值。

独立 Collector 的价值是能严格筛选 Batch/Sheddable 流量，并按控制窗口重新聚合，而不是混用模型全部流量。

## 6. 队列负载公式

```text
queue_load_ratio = queue.waiting / queue.running
```

特殊情况：

| waiting | running | ratio |
| ---: | ---: | --- |
| 0 | 0 | 0 |
| >0 | 0 | missing |
| 任意 | >0 | waiting/running |

空队列被视为健康；有等待但 running=0 时无法做除法，当前记 missing。

`Risk`：`waiting>0 && running=0` 往往是严重异常，却会因 missing 导致该 KSN 被排除，而不是 rollback。建议额外定义 `stalled` 信号并最高优先级回退/告警。

## 7. KSN 采样过滤

只有以下 View 才参与：

- kind=isvc；
- state=active；
- model 与 KConf 模型一致；
- KSN 非空；
- ISVC Runtime 显示属于合法 Batch pool；
- Runtime ReadyReplicas > 0。

KConf 已配置 KSN 也会尝试采样；运行时发现的新 KSN 可以纳入。多个 View 对同一 model/KSN/pool 匹配时视为 ambiguous并跳过，避免随意选择错误指标。

## 8. 滑动窗口存储

每 `(modelServiceName, KSN)` 一个 Redis ZSET：

```text
batch-inference:auto-tuner:metrics:{model}:{ksn}
score  = sample timestamp(ms)
member = JSON sample
```

写入时清除窗口之前的数据、ZADD 当前样本并刷新 TTL。决策时读取窗口内样本并分别计算：

```text
avg(success_rate over non-missing samples)
avg(queue_load_ratio over non-missing samples)
```

同时保留 window_samples、各信号有效样本数和 source，便于判断是不是“平均值正常但有效点太少”。

## 9. Redis 故障边界

- Redis client 不存在：测试/降级场景使用进程本地窗口。
- Redis client 存在但写失败：只记录 warning，当前实现不会再写本地窗口。
- Gateway Collector 使用 Kafka auto-commit；Redis 不可用时样本丢弃，之后回退 Scaler。
- ZSET member 是完整 JSON；同毫秒且内容完全相同的样本可能因 member 相同被去重，正常全局采样每周期一次，影响很小。

## 10. 样本平均的统计边界

当前是对每个采样点的比率做算术平均，不是按请求总量加权。例如两个点分别为 10/10 和 900/1000，平均比率为 95%，全量比率约 90.1%。独立 Gateway Collector 则先累计 success/total 后计算，更符合请求级加权成功率。

这也是决策阶段优先使用 Gateway 聚合值的一个理由。

## 11. 面试表达

> 成功率只统计 Sheddable 离线流量，并把 2xx 视为成功、429和5xx视为容量失败，主动排除业务4xx。30秒分桶、10分钟窗口且至少100个样本，避免小样本误调。第二个信号是 waiting/running，它描述模型排队压力。独立 Gateway 数据足够时覆盖 Scaler 成功率，不足时安全回退。

## 12. 源码定位

- `internal/service/gatewaymetrics/request_success_collector.go`
- `internal/scaler/views.go`
- `internal/service/modelconcurrency/model_concurrency_autotuner_metrics.go`
- `internal/service/modelconcurrency/model_concurrency_autotuner_state.go`
- `services/llm/openai.go` Sheddable header

