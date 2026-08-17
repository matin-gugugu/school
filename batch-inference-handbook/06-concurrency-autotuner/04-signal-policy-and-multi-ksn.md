# 信号决策、步长与多 KSN 聚合

## 1. 信号分级

默认阈值：

### 成功率

```text
rate < 0.990  → bad
rate > 0.995  → good
其他          → ok
无值          → missing
```

### 队列负载

```text
ratio > 1.0  → bad
ratio < 0.4  → good
其他         → ok
无值         → missing
```

严格使用 `<`/`>`，所以恰好 0.990、0.995、0.4、1.0 都属于 ok。两个阈值之间形成迟滞区，防止并发在单一边界附近来回震荡。

## 2. 单 KSN 决策矩阵

| success | queue | 决策 |
| --- | --- | --- |
| 任一 missing | 任意 | insufficient_metrics |
| 任一 bad | 任意 | rollback |
| good | good | probe_fast |
| good | ok | probe_slow |
| ok | good | probe_slow |
| 其他 | 其他 | hold |

成功率代表错误风险，队列比代表压力。必须两个都健康才快探；一个健康一个中性只慢探；任一恶化立即回退。

## 3. 调整步长

步长以“当前有效容量上界”而不是当前并发为基数：

```text
fast step     = ceil(upperBound × 5%)
slow step     = ceil(upperBound × 2%)
rollback step = ceil(upperBound × 10%)
```

```text
probe:    target = current + step
rollback: target = current - step
hold:     target = current
target = clamp(target, min, upperBound)
```

至少移动 1。回退比上探更快，体现风险不对称。

示例：上界 500、当前 200：

```text
fast → 225
slow → 210
rollback → 150
```

## 4. 首轮探索

没有可用 previous upper bound 时，不从当前值继续探，而是：

```text
target = clamp(initialExploreGoroutine, min, upperBound)
```

默认初始值 100。这让首次开启自动调谐从统一、相对保守的点开始。

配置中有 `upper_bound_change_reset_threshold`（默认20%），但“上界显著变化后重置到初始探索”的代码当前被注释禁用；后续副本变化仍走正常决策，只由 clamp 限制新上界。

## 5. 为什么按上界算步长

如果按 current 的比例，低位探索很慢；按上界比例可以让不同规模模型在相似的轮数内覆盖搜索区间。例如 5% 上界理论上约 20 个快探步从低位走到上限。

代价是大容量模型的绝对步长较大，因此滑动窗口和 rollback 必须可靠。

## 6. 缺指标 KSN 的处理

每个匹配 KSN 先独立决策。decision 不存在或为 insufficient_metrics 时：

- 加入 excluded KSN；
- 不参与决策聚合；
- 其 Ready Capacity 也不计入有效上界；
- 记录排除原因和容量。

如果所有 KSN 都被排除：

```text
decision = hold
target = current
upperBound = 0（表示无有效自动上界）
不覆盖上一次有效 AutoTuner 状态
```

这避免短暂观测缺失把 current 强行 clamp 到 1。

## 7. 多 KSN 决策优先级

对有效 KSN 聚合：

```text
rollback > hold > probe_slow > probe_fast
```

更完整地说：

1. 任一 KSN rollback → 整模型 rollback；
2. 任一 KSN hold → 整模型 hold；
3. 全部可探，且至少一个 slow → slow；
4. 全部 fast → fast。

`AggregateAutoTuneDecision` 本身还有 insufficient→hold 分支，但缺指标 KSN 已在选择阶段排除，所以正常主链路不会把 insufficient decision 传入聚合。

## 8. 保守聚合的含义

模型的多个 KSN 共享一个 Batch WorkPool cap，而 Gateway 可能把请求路由到任一 KSN。只要一个有效 KSN 过载，就不能假设其他 KSN 的健康能抵消它，因此 rollback 优先。

但这也可能让小容量异常 KSN拖累全模型。进一步可按路由权重/容量做：

- 独立 KSN 并发预算；
- 异常 KSN 摘流；
- 按容量加权信号，但保留硬错误 veto；
- 调整 Gateway 路由权重而非只调总并发。

## 9. 控制稳定性

现有稳定机制：

- good/bad 双阈值迟滞；
- 10 分钟平滑窗口；
- 5 分钟调节周期；
- 上探小步、回退大步；
- 硬容量上界；
- 样本不足保持/排除。

仍可增加：

- 决策连续 N 轮确认；
- full jitter/随机探索避免多模型同步；
- 调整后冷却期；
- SLO 紧急熔断；
- PID/AIMD 或 bandit，但必须保持可解释和安全约束。

现策略本质接近带硬上界的 AIMD 变体：加性上升、较大步长下降。

## 10. 面试表达

> 我没有用单阈值开关，而是给成功率和队列比各设 good/ok/bad 区间形成迟滞。两个都好快探，一个好一个中性慢探，任一坏就回退。步长分别是有效上界的5%、2%和10%，升慢降快。多 KSN 时先排除缺指标的容量，再以 rollback、hold、slow、fast 的保守优先级聚合。

## 11. 源码定位

- `internal/service/modelconcurrency/model_concurrency_signal.go`
- `internal/service/modelconcurrency/model_concurrency_reconciler.go: selectAutoTuneKSNs`
- `internal/service/modelconcurrency/model_concurrency_reconciler.go: applyAutoTuneKSNSelection`
- `internal/config/model_concurrency_tuning_config.go`

