# 文件与消息两种结果交付

## 1. 文件模式

普通 JSONL Task 的结果路径为：

```text
tasks/{taskID}/output/shards/shard_0000_data.jsonl
tasks/{taskID}/output/shards/shard_0001_data.jsonl
...
tasks/{taskID}/output/failed/shard_0000_failed_reqs.jsonl
tasks/{taskID}/output/results.jsonl
```

每个 Shard 的响应先保存为 JSONL，全部 Shard 完成后按索引流式合并到 `results.jsonl`。Merge 成功后 MySQL `output_file` 写：

```json
{
  "type": "s3",
  "info": {
    "bucket": "运行环境bucket",
    "key": "tasks/{taskID}/output/results.jsonl"
  }
}
```

用户通过查询 Batch 获取结果位置，再通过平台约定下载。

## 2. 结果 JSONL 结构

每一行是 BatchResponse：

```json
{
  "id": "request-id",
  "custom_id": "business-id",
  "response": {
    "id": "business-id",
    "body": {}
  },
  "error": ""
}
```

失败请求同样占一行，但 `error` 非空。单独的 failed request 文件保存原始 BatchRequest，便于修正后重新提交。

## 3. 消息模式的注册

创建任务时若提供 `result_topic`/`tag`，TaskCreator 把路由写 Redis：

```text
provide_topic:{taskID} → encode(resultTopic, tag)
TTL = 168 hours
```

Executor 通过 Task ID 查询这份路由来判断消息模式。读取最多重试 5 次、间隔 1 秒；Redis 无 Key 则按文件模式处理。

这份临时路由没有落在 MySQL Task 主记录中，是消息交付的重要控制状态。

## 4. 两段式 Kafka 路由

Executor 并不直接向用户指定 topic 发送，而是把每条 TaskReqResult 发到平台统一 `task_req_result_topic`：

```json
{
  "task_id": "...",
  "time": 0,
  "model_service_name": "...",
  "tag": "user-tag",
  "result_topic": "user-topic",
  "batch_response": {}
}
```

下游 Result Dispatcher 再根据 `result_topic/tag` 投递。这种设计把业务 topic 权限、路由、重试和生产者连接从 Executor 解耦。

## 5. 投递时机和语义

Shard 请求处理结束后，`SendResultMessage` 以 goroutine 异步执行：

- 每个 Response 生成一条 Kafka message；
- 每条最多尝试发送 5 次；
- 某条失败不阻断其余消息；
- 批量结束后若存在失败，记录日志和指标；
- 不会把 Shard 或 Task 改为 failed。

因此消息交付是 best-effort + producer retry，不是事务性 outbox。Executor 崩溃或 Shard 恢复可能导致消息丢失或重复，消费端需要按 `(taskID, requestID)` 幂等。

## 6. 消息模式仍有文件兜底

代码仍保存 Shard OSS 结果。最终 Merge 在 `isMessageType=true` 时只处理第一个 Shard，注释也说明“暂时只合并一个文件”。这更像兼容性占位，而不是完整消息任务归档。

`Risk`：如果消息 Task 实际包含多个 Shard，MySQL output_file 指向的 `results.jsonl` 不是全量结果。需要明确产品契约：

- 消息模式不承诺文件结果；或
- 无论模式都合并全量文件；或
- 独立写 manifest，列出所有 Shard 文件。

## 7. Task 状态通知与结果消息

至少存在两类 Kafka 语义：

- Task Notice：Running/Finish/Failed/Expired 等生命周期事件；
- TaskReqResult：每条模型请求的业务结果。

Running Notice 用 Task 级 ExecuteOnce 去重；结果消息没有同等发送端去重。两者不能用同一消费语义处理。

## 8. 更可靠的消息交付方案

建议采用 Outbox：

```text
Shard结果持久化
  → 原子登记待投递记录/manifest
  → 独立Dispatcher发送Kafka
  → 记录delivery状态与attempt
  → 对账器补发
```

若 MySQL 不适合保存百万条结果，可把 OSS Shard Result 作为事实源，Outbox 只保存 Shard manifest 和发送游标。

## 9. 面试表达

> 平台同时支持文件和消息交付。文件模式先落确定性的 Shard JSONL，再按 ShardIndex 合并，结果顺序稳定；消息模式把用户 topic/tag 注册在 Redis，Executor 把统一格式发到平台中转 topic，由下游路由。当前消息是 at-least/best-effort 边界，消费端要按 taskID+requestID 幂等，进一步可以用基于 OSS manifest 的 Outbox 做补发和对账。

## 10. 源码定位

- `scheduler/executor/executor.go: SendResultMessage`
- `scheduler/executor/executor.go: GetMessageTopic`
- `services/mq/producer.go`
- `internal/models/task_req_result.go`
- `manager/task_creator.go` 消息路由注册
- `pkg/utils/provide_type.go`
- `pkg/utils/oss_file_utils.go`

