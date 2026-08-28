# 请求重试、退避与错误分层

## 1. 三层失败

| 层级 | 例子 | 处理方式 |
| --- | --- | --- |
| Task | 输入非法、账号冻结、最终合并失败 | Task 进入 failed/expired/stopped |
| Shard | OSS 下载失败、模型解析失败、Ready 探测异常 | Metadata failed，进入 Shard 恢复链路 |
| Request | 单次 Gateway 4xx/5xx、流中断 | 请求级重试或记录错误，其他请求继续 |

不要把“Request 有失败”直接等价为“Task failed”。Task 可以 completed，同时 success_count 与 failed_count 都大于 0。

## 2. 可重试状态码

Gateway 返回以下状态码时允许请求级重试：

```text
429 Too Many Requests
529 自定义过载/Watchdog超时
500、501、502、503、504、505
```

OpenAI SDK 错误能解析出 HTTP 状态且不在列表中时，不重试。其他无法识别为 `openai.Error` 的网络/流错误当前默认可重试。

这体现了错误分类原则：

- 容量不足和瞬时服务端故障可能恢复；
- 参数错误、鉴权错误等确定性 4xx 立即失败；
- 未知传输错误按瞬时故障处理。

## 3. 重试次数语义

主循环是：

```go
for attempt := 0; attempt < maxRetries; attempt++
```

因此配置字段 `MaxRetry` 在代码里实际表示“最多 attempt 总数”，而不是“首次请求之外再重试 N 次”。例如值为 3，最多调用 Gateway 3 次。

最终错误文本中的 `Failed after %d attempts` 使用零基 attempt，可能比人的自然语言次数少 1，是可改进的可观测性细节。

## 4. 指数退避

第 `attempt` 次失败后：

```text
backoff = min(baseDelay × 2^attempt, maxRetryDelay)
```

随后 `time.Sleep(backoff)` 再进入下一次 attempt。

优点是快速错误不会形成紧密重试风暴；上限避免等待无限增长。

`Risk`：退避没有 jitter，大量请求同时遇到 429/529 时可能同步醒来形成惊群；`time.Sleep` 也不响应 context 取消。建议使用 full jitter，并用 timer + select 监听 context。

## 5. 每次重试前重新确认什么

每个 attempt 开始前会依次：

1. 检查 Shard context 是否取消；
2. 检查账号是否冻结；
3. 重新获取模型信息；
4. 等待运行时模型服务存在 Ready KSN；
5. 调用 Gateway。

这种方式使长时间重试可以适应路由切换和副本恢复，但会增加模型元数据与 Ready 探测开销，本地缓存和 singleflight 用于抑制放大。

## 6. 错误如何落盘

请求最终失败时：

- `results[index]` 写入 ID、custom ID 和 Error；
- 原始 BatchRequest 加入 `failedReqs`；
- 结束时写 `{task}/{shard}/failed_requests.jsonl`；
- 结果 JSONL 本身也包含错误响应；
- Redis 实时进度失败数 +1；
- 打点 `request_final_counter{result=fail}`。

`failedReqs` 由多个 WorkPool goroutine 并发 append，使用进程级互斥锁保护。该锁是全局锁，不仅限于一个 Shard，吞吐极高时可以改成每 Shard 锁或 channel 汇聚。

## 7. 结果与状态失败的边界

| 情况 | Request 结果 | Shard 状态 | Task 可能结果 |
| --- | --- | --- | --- |
| 400 参数错误 | error | completed | completed + failed_count |
| 503 重试后成功 | success | completed | completed |
| 503 达最大 attempts | error | completed | completed + failed_count |
| OSS Shard 下载失败 | 无完整结果 | failed | failed |
| 账号冻结 | 当前/后续请求中止 | failed | failed |
| 最终 Merge 失败 | 分片结果已存在 | completed shards | Task failed |

## 8. Shard 重试与 Request 重试的关系

Request 重试发生在一次 Shard 执行内部；Shard failed queue/升级恢复会重新执行整个 Shard。因此一次请求的总 Gateway 调用次数理论上可能是：

```text
请求级 attempts × Shard 执行 attempts
```

当前没有端到端 exactly-once。调用 Gateway 前后如果实例崩溃，恢复实例无法判断推理是否已经成功，可能产生重复请求和重复计费。稳定 request ID 为下游幂等提供了条件，但是否真正去重要看 Gateway 契约。

## 9. 与并发自动调谐的联系

429、529、5xx 属于容量调谐重点关注的失败。单纯增加重试可能掩盖瞬时失败，却会：

- 增加总耗时；
- 放大 Gateway 压力；
- 降低任务窗口内完成率；
- 增加重复计费风险。

自动调谐通过降低并发从源头减少容量失败，重试则作为剩余瞬态故障的最后保护，两者职责不同。

## 10. 面试表达

> 我把错误分成 Request、Shard 和 Task 三层。429、529 以及 500到505 做请求级指数退避，确定性 4xx 直接失败；请求最终失败只记入 failed_count，不阻断同分片其他请求。基础设施错误才触发 Shard 恢复。由于 Shard 恢复可能重复调用 Gateway，当前语义是 at-least-once，稳定 request ID 和下游幂等是进一步保证 exactly-once effect 的关键。

## 11. 源码定位

- `scheduler/executor/executor.go: shouldRetryOpenAIStatusCode`
- `scheduler/executor/executor.go: funcCall`
- `scheduler/executor/executor.go: handleRequest`
- `scheduler/executor/executor.go: saveFailedReq`
- `internal/config/config.go: WorkerConfig`

