# Task 与 Shard 数据模型

## 1. BatchTask

BatchTask 是 MySQL 中的任务主记录。简化结构如下：

```go
type BatchTask struct {
    ID               string
    CreatedAt        int64
    UpdatedAt        int64
    DeletedAt        int64

    Endpoint         string
    ProjectID        string
    Model            string
    CompletionWindow int

    InputFile        JSON
    OutputFile       JSON
    ErrorFile        JSON
    Metadata         JSON
    Errors           JSON

    Status           string
    RunningAt        int64
    ExpiredAt        int64
    CompletedAt      int64
    FailedAt         int64
    StoppingAt       int64
    StoppedAt        int64

    TotalCount       int
    SuccessCount     int
    FailedCount      int
}
```

### 1.1 ID 与默认值

- ID 自动生成为 `bt-{uuid}`。
- 创建状态固定为 `init`。
- `created_at`、`updated_at` 使用 Unix 秒。
- API 响应中的 `request_counts` 不是数据库列，而是查询后从计数字段构造。

### 1.2 Metadata

当前创建链路至少保存：

```json
{
  "description": "用户描述",
  "customer_id": "账号或 API Key ID",
  "billing_model_id": "计费模型 ID"
}
```

账号冻结扫描依赖 `customer_id` 和 `billing_model_id`。

### 1.3 InputFile/OutputFile

输入示例：

```json
{
  "type": "url",
  "info": {
    "bucket": "",
    "key": "",
    "url": "https://.../dataset.jsonl"
  }
}
```

完成后的输出指向平台 OSS：

```json
{
  "type": "s3",
  "info": {
    "bucket": "<configured-bucket>",
    "key": "tasks/{taskID}/output/results.jsonl"
  }
}
```

## 2. BatchRequest 与 BatchResponse

### 2.1 输入行

```json
{
  "id": "创建分片时由平台生成",
  "custom_id": "用户提供的关联 ID",
  "url": "/v1/chat/completions",
  "body": {
    "model": "原始模型字段会在执行时覆盖",
    "messages": []
  }
}
```

平台在创建 Shard 时把 `id` 更新为 `batch-{uuid}`。`custom_id` 用于用户关联输入输出。

### 2.2 输出行

成功：

```json
{
  "id": "batch-uuid",
  "custom_id": "user-id",
  "response": {
    "id": "user-id",
    "body": {}
  }
}
```

失败：

```json
{
  "id": "batch-uuid",
  "custom_id": "user-id",
  "error": "Failed after N attempts: ..."
}
```

每条输入最终都应对应一个 BatchResponse，成功或失败都可写入最终结果。

## 3. ShardMetadata

Shard 元数据保存在 OSS，而不是当前主链路的 MySQL 表中。

```go
type ShardMetadata struct {
    ShardID      string
    TaskID       string
    ShardIndex   int
    StartLine    int64
    EndLine      int64
    TotalLines   int64
    FileSize     int64
    ObjectKey    string

    Status       ShardStatus
    SuccessCount int64
    FailedCount  int64
    ProcessedAt  time.Time
    CompletedAt  time.Time
    ErrorMessage string

    ModelID          string
    BillingModelID   string
    ModelScope       string
    ModelProjectID   string
    ModelServiceName string
    ProjectID        string
    CustomerID       string
    APIKey           string
    TaskName         string
}
```

### 3.1 Shard ID

格式：

```text
{taskID}_{shardIndex:04d}
```

### 3.2 行号范围

当前实现使用闭区间：

```text
TotalLines = EndLine - StartLine + 1
```

第一个 Shard 从 0 开始。

### 3.3 状态

```text
pending → processing → completed
                     ↘ failed
```

Shard 完成后，`SuccessCount + FailedCount` 应等于 `TotalLines`。

## 4. TaskMetadata

```go
type TaskMetadata struct {
    TaskID      string
    TotalLines  int64
    TotalShards int
    Shards      []*ShardMetadata

    ProvideType string
    ResultTopic string
    Tag         string

    CreatedAt   time.Time
    UpdatedAt   time.Time
}
```

它的主要用途是：

- 枚举任务所有 Shard；
- 汇总任务进度；
- 按 ShardIndex 合并结果；
- 判断 File/Message 交付方式；
- 保留用户结果 Topic 和 Tag。

TaskMetadata 中嵌入的是创建时的 ShardMetadata 快照。执行完成状态需要重新下载每个独立的 `shard_*_meta.json`，不能只读取 TaskMetadata 内嵌状态。

## 5. TaskMessage

API 向 TaskCreator 传递进程内消息：

```go
type TaskMessage struct {
    TaskID, TaskName, DatasetURL string
    ProjectID, CustomerID, APIKey string
    ModelID, BillingModelID string
    ModelScope, ModelProjectID string
    ModelName, ModelServiceName string
    ProvideMethod, ResultTopic, Tag string
}
```

虽然结构名为 Message，当前创建主链路并没有把它持久化到 Kafka，而是直接作为 goroutine 参数传给 TaskCreator。

## 6. TaskReqResult

Message 模式逐条结果结构：

```go
type TaskReqResult struct {
    TaskID           string
    Time             int64
    ModelServiceName string
    Tag              string
    ResultTopic      string
    BatchResponse    BatchResponse
}
```

平台 Kafka Topic 和用户业务 ResultTopic 是两个概念：前者是系统投递入口，后者作为字段交给下游路由。

## 7. 计数关系

理想不变量：

```text
Task.TotalCount
  = Σ Shard.TotalLines
  = Task.SuccessCount + Task.FailedCount

Shard.TotalLines
  = Shard.SuccessCount + Shard.FailedCount
```

运行过程中 MySQL 终态计数、OSS Shard 元数据和 Redis 实时进度可能短暂不一致，读取策略见 `04-data-ownership.md`。
