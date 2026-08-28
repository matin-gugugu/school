# Batch API 与任务创建

## 1. 模块目标

任务接入层把一个外部 HTTP 请求转换为：

1. 可查询的 MySQL BatchTask；
2. 包含模型、账号和数据集上下文的 TaskMessage；
3. 后台 TaskCreator 分片任务。

API 成功只表示“任务主记录已经创建”，不表示输入文件已经校验或 Shard 已经入队。

## 2. 创建请求

核心请求结构：

```json
{
  "completion_window": 86400,
  "input_file": {
    "type": "url",
    "info": {
      "bucket": "",
      "key": "",
      "url": "https://source/dataset.jsonl"
    }
  },
  "project_id": "project",
  "customer_id": "customer",
  "endpoint": "/v1/chat/completions",
  "model": "model-instance-id",
  "model_scope": "public",
  "provide_method": "file",
  "result_topic": "",
  "tag": "",
  "metadata": {
    "description": "batch description"
  }
}
```

### 2.1 重要 Header

| Header | 用途 |
| --- | --- |
| `X-Ks-Wq-Api-Key-Id` | 默认账号 ID、Executor Gateway Header、User ID |
| `X-Ks-Wq-Project-Id` | 默认项目 ID |
| `X-Ks-Wq-Workload-Name` | TaskName，透传给 Gateway |
| `X-Ks-Model-Name` | 业务模型名，透传给 Gateway |
| `X-Ks-Extra-Attr1` | 额外属性透传 |

如果 Body 未提供 `project_id` 或 `customer_id`，会分别回退到项目 Header 和 API Key ID。

## 3. 模型实例解析

`model` 必填。`model_scope` 可为空、`public` 或 `private`。

查询规则：

```text
scope=public
  → model_instances

scope=private
  → private_model_instances

scope为空
  → 先查 public
  → public 不存在再查 private
```

返回结果至少需要：

- `model_service_name`：调度队列和实际运行模型；
- `model_id`：Billing 使用；
- `model_scope`：执行时模型查询分支；
- `model_project_id`：私有模型必填。

私有模型实例缺少 `model_project_id` 时，创建请求直接失败。

## 4. MySQL 任务创建

API 构造 BatchTask：

```text
InputFile        = 原始 input_file JSON
ProjectId        = 请求或 Header 项目
Endpoint         = 请求 endpoint
ModelName        = 请求 model（模型实例 ID）
Metadata         = description/customer_id/billing_model_id
CompletionWindow = 用户完成窗口
```

GORM `BeforeCreate` 自动生成：

```text
ID        = bt-{uuid}
Status    = init
CreatedAt = now Unix seconds
UpdatedAt = now Unix seconds
```

## 5. TaskCreator 启动

数据库创建成功后：

```go
go TaskCreator.CreateTask(TaskMessage{...})
```

TaskMessage 携带：

- TaskID 和数据集 URL；
- 项目、账号、API Key；
- 模型实例 ID、Billing 模型 ID；
- 模型作用域、私有项目 ID；
- ModelServiceName；
- 文件或消息结果交付信息。

API 随后立即返回创建的 BatchTask，通常状态仍是 `init`。

## 6. 初始化结果

### 成功

TaskCreator 完成校验、分片、元数据上传和全部 Shard 入队后：

```text
INIT_SUCCESS
status      init → pending
total_count = JSONL 总行数
```

### 失败

任何初始化阶段错误：

```text
INIT_FAIL
status    init → failed
failed_at = now
errors    = {taskID: errorMessage}
```

## 7. 其他 Batch API

### 7.1 查询

- 单任务查询优先读 Redis Task Cache，未命中查 MySQL。
- 非终态任务再读取 Redis 实时进度，覆盖响应的 completed/failed。
- 批量查询最多支持 20 个 batch ID。

### 7.2 延长 Completion Window

只允许：

- 当前状态为 init/pending/running；
- 新窗口大于旧窗口；
- 新值在 int32 正数范围。

API 先把新 Deadline 写入短 TTL 乐观缓存，再用数据库条件更新，最后刷新正常缓存。

### 7.3 取消

当前实现直接写 `stopped`，并设置 stopping/stopped 时间。Executor 后续状态检查会终止剩余请求。

### 7.4 删除

调用 GORM Delete 删除 BatchTask，并清理 Task Cache 和实时进度。API 没有通过状态机的 DELETE 事件转为 `deleted`。

## 8. 可靠性边界

### 8.1 本地 goroutine 不具备持久化语义

风险窗口：

```text
MySQL INSERT 成功
→ API 返回成功
→ 进程退出
→ TaskCreator 未完成/未启动
```

结果可能是任务长期停在 `init`。仓库中 TaskReconciler 只有 TODO，尚未自动修复。

### 8.2 API 重试与幂等

当前创建 API 没有显式 client idempotency key。客户端超时后重试可能创建多个 BatchTask。可以演进为：

- 接收用户幂等键并建唯一索引；
- Transactional Outbox；
- 持久化 TaskCreate MQ；
- Reconciler 扫描长时间 init 任务。

## 9. 面试问题

### 为什么先创建数据库任务，再异步分片？

大文件校验和分片耗时可能达到分钟级，不能阻塞 HTTP 请求。先返回 TaskID 可以让调用方异步轮询。但异步边界需要持久化或补偿机制，当前本地 goroutine 是可改进点。

### 为什么创建阶段要查询模型实例？

调度队列和并发池以 model_service_name 为维度，Billing 又需要模型产品 ID；用户输入的 model instance ID 无法直接满足后续执行和治理需求。

## 10. 源码定位

| 内容 | 文件/函数 |
| --- | --- |
| 路由 | `internal/service/apiserver/api_batch/api.go` |
| 创建任务 | `api_batch.go: CreateBatch` |
| 查询/取消/超时 | `api_batch.go` 对应 Handler |
| BatchTask Hook | `internal/models/db/batch_task.go` |
| 公私模型查询 | `internal/client/store/msql/store_model_instances.go` |
| TaskCreator | `manager/task_creator.go: CreateTask` |
