# 请求执行与模型 Gateway

## 1. 单行 JSONL 的含义

每行被解析为 `BatchRequest`，核心字段包括：

```json
{
  "id": "平台请求ID",
  "custom_id": "业务关联ID",
  "method": "POST",
  "url": "/v1/chat/completions",
  "body": {
    "model": "提交时模型名",
    "messages": [],
    "stream": false
  }
}
```

当前执行实现最终走 OpenAI-compatible Chat Completions。`method`、`url` 是批任务协议的一部分，但实际调用路径在 `handleRequest` 中固定为 Chat Completions，不是任意 HTTP 代理。

## 2. 模型信息解析

Task Metadata 同时保留用户模型 ID、模型名、scope、project ID 和提交时服务名。执行前调用：

```text
GetModelInfoByScope(modelID, modelScope, modelProjectID)
```

模型缓存约 5 分钟，并区分 public/private 查询路径。拿到最新 `ModelServiceName` 后，会覆盖请求体中的 `model` 字段。

这解决了任务排队期间模型实例名发生变化的问题，但也意味着：同一任务跨越模型变更窗口时，不同请求理论上可能落到不同运行版本。若业务需要严格版本一致，应在 Task Metadata 固化 deployment revision。

## 3. Ready KSN 门禁

提交 Shard 前以及每次请求 attempt 前都会检查模型服务是否有 Ready 副本：

- 通过模型 KSN 配置和 ISVC Runtime 查询副本状态；
- public 模型只接受离线资源池；
- private 模型允许非离线资源池；
- 本地结果缓存 1 秒，并用 singleflight 合并并发探测；
- 无 Ready 或探测失败时按 5、10、20、40、60 秒等待，之后保持 60 秒上限。

若模型无法检查或已有 Ready 副本则继续执行。

`Risk`：Shard 级首次检查传入 `context.Background()`，没有独立最大等待截止时间；模型长期无 Ready 副本时可能一直等待。请求 attempt 级检查使用 Shard context，可在账号冻结时被取消，但任务取消并不会主动取消这个 context。

## 4. WorkPool 提交

所有请求提交到以 `shardMetaData.ModelServiceName` 为 key 的模型级 WorkPool：

```text
model A → pool(cap=N_A)
model B → pool(cap=N_B)
```

动态 KConf 更新会修改 pool cap；并发自动探测调整的正是这里的请求并发上限。若模型不存在配置，运行时回退为默认 10。

## 5. Gateway Client

每次请求构建 OpenAI Client，BaseURL 指向模型 Gateway，整请求超时由 `http_req_timeout_minutes` 控制。网络参数包括：

- TCP connect timeout：5 秒；
- TLS handshake timeout：15 秒；
- Expect-Continue timeout：1 秒；
- KeepAlive：30 秒；
- 总请求超时：配置分钟数。

调用携带的路由/归因信息包括项目、API Key ID、provider、scene、traffic platform/source、Task ID/名称、模型 ID/名称、request ID 和用户 ID。

此外固定携带：

```text
X-Ks-Wq-Request-Schedule-Priority: Sheddable
```

这表明批量流量属于可降级/可让渡优先级，便于在线高优流量和离线吞吐共用 Gateway 时做隔离。

## 6. 非流式请求

```text
Chat.Completions.New(ctx, params)
  → 成功：写入 results[index].Response.Body
  → 失败：识别错误是否可重试
```

输出封装为 BatchResponse，保留平台请求 ID 和 custom ID。

## 7. 流式请求

当 `body.stream=true`：

1. 建立 streaming Chat Completion；
2. 顺序消费所有 chunk；
3. 通过 `ChatCompletionAccumulator` 聚合；
4. 流结束后写成一个完整 ChatCompletion 结果。

这里“支持输入请求指定 stream”不等于“向批任务用户实时返回 token”。批任务仍要等请求完成后保存聚合结果。

## 8. 扩展字段解析

执行使用 `UnmarshalWithValidation` 把 JSON body 转成 SDK 参数，同时兼容扩展字段。最终仍会将模型服务名覆盖为运行时解析值，防止用户 body 绕过任务绑定的模型路由。

## 9. 请求结果语义

单条模型失败通常不会让整个 Shard 的 `processShardData` 返回错误，而是：

- 在对应 `results[index]` 写 Error；
- 记录到 failedReqs；
- 实时进度计入失败；
- Shard 本身在执行流程正常结束后可标 completed；
- Task 最终可能 completed，但带 `failed_count > 0`。

Shard failed 表示基础设施/执行流程无法完成该分片；Request failed 表示分片执行完成但某些业务请求失败，二者必须区分。

## 10. 风险与改进

- 每 attempt 重建 Client/Transport，连接池复用范围有限；可以按路由维度复用 Client。
- 模型缓存会带来短暂旧路由，应结合部署 revision 或强一致查询策略。
- Ready 等待需要 Task deadline/cancel context。
- 当前执行协议实际集中于 Chat Completions；若接口宣称通用 Batch endpoint，需要按 URL 分发不同 handler。
- 固定 Sheddable 优先级合理，但应让自动调谐指标只统计同一流量类别，避免在线流量污染信号。

## 11. 源码定位

- `scheduler/executor/executor.go: funcCall`
- `scheduler/executor/executor.go: handleRequest`
- `scheduler/executor/executor.go: waitForReadyKSNReplicasWithLog`
- `services/llm/openai.go`
- `internal/service/modelcache/modelcache.go`
- `internal/isvc/`

