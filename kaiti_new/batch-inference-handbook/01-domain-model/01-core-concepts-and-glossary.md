# 核心概念与术语

## 1. 任务层级

```text
BatchTask
  ├── TaskMetadata
  │   ├── ShardMetadata[0]
  │   │   ├── BatchRequest[0]
  │   │   ├── BatchRequest[1]
  │   │   └── ...
  │   ├── ShardMetadata[1]
  │   └── ...
  └── Final Result / Message Results
```

| 术语 | 含义 |
| --- | --- |
| Batch/BatchTask | 用户提交的一次批量推理作业，也是 API 和 MySQL 中的主实体 |
| Task | 代码中有时与 Batch 同义，例如 TaskCreator、TaskID |
| Dataset | 用户通过 URL 提供的 JSONL 输入文件 |
| BatchRequest | JSONL 中的一行模型请求 |
| Shard | 为调度和执行而切分的一段连续 JSONL 请求 |
| BatchResponse | 单个 BatchRequest 的成功响应或错误结果 |
| TaskMetadata | 保存任务包含哪些 Shard、总行数和结果交付方式的 OSS JSON |
| ShardMetadata | 保存单 Shard 范围、模型信息、状态和计数的 OSS JSON |

## 2. 模型标识

模型相关字段最容易混淆。

| 字段 | 来源 | 作用 |
| --- | --- | --- |
| `BatchTask.ModelName` | 创建请求中的 `model` | 实际保存的是模型实例 ID，用于任务记录和后续关联 |
| `TaskMessage.ModelID` | 创建请求中的 `model` | 执行时重新获取模型实例信息 |
| `ModelServiceName` | model_instances/private_model_instances | Redis 队列名、并发池、Gateway 请求实际模型名 |
| `ModelName` | Header `X-Ks-Model-Name` | 透传给 Gateway 的展示/业务模型名 |
| `BillingModelID` | model instance 关联的模型 ID | Billing 资源冻结检查 |
| `ModelScope` | `public` 或 `private` | 决定模型元数据查询路径和 Ready Pool 过滤规则 |
| `ModelProjectID` | 私有模型实例所属项目 | 私有模型 OpenAPI 查询所需上下文 |

### 2.1 为什么需要区分

- 用户提交的是模型实例，不一定等于底层运行服务名。
- 模型服务可能迁移或更新，Executor 每次重试前会重新解析运行时 `model_service_name`。
- 计费通常按模型产品 ID，不按 KSN 或服务名。
- 私有模型查询需要项目隔离，公有模型不需要。

## 3. KSN、ISVC 和 Pool

| 术语 | 含义 |
| --- | --- |
| ISVC | InferenceService 运行实例描述，提供 Ready 副本、卡型、标签等信息 |
| KSN | 可定位某组模型推理运行时的服务标识；KConf 为每个 KSN 配置单副本并发 |
| Pool | 推理资源池，例如 `offline`；公有 Batch 模型默认只考虑离线池 |
| Ready Replicas | 当前可接收请求的副本数 |
| Device Type | X40/X50/X60 等卡型，用于从基准并发推导单副本能力 |

私有模型通过 `model_scope=private` 显式隔离，因此 Ready 检查和自动调谐允许使用非 offline Pool；公有模型保留 offline-only 约束。

## 4. 两类并发

### 4.1 Shard 并发

`max_execute_shard` 控制一个模型同时有多少个 Shard 处于执行阶段。它限制：

- 同时占用的 Shard 内存；
- 同时进行的 OSS 下载/上传；
- 单模型任务间并行度；
- process queue 中活跃任务数量。

### 4.2 Request 并发

`max_execute_goroutine` 控制一个模型同时有多少条请求进入 Gateway。它对应模型专属 ants Worker Pool 的容量。

一个 Shard 可以包含数千条 Request，因此：

```text
Shard 并发 != 请求并发
```

## 5. 调度队列术语

| 队列 | 含义 |
| --- | --- |
| pending queue | 已完成分片，尚未被执行器领取 |
| process queue | 已被领取，正在执行或等待故障恢复 |
| failed queue | Shard 级执行失败，等待延迟重试 |

队列元素不是仅保存 ShardID，而是拼接：

```text
modelName#shardDatasetKey#shardMetadataKey#shardOutputKey#joinTimestamp
```

## 6. 结果交付术语

| 类型 | 含义 |
| --- | --- |
| File Provide | 所有 Shard 结果合并为 `tasks/{taskID}/output/results.jsonl` |
| Message Provide | 每条结果封装后写 Kafka，消息中携带用户结果 Topic 和 Tag |
| Failed Request File | 保存最终失败请求原文，用于排查或重放 |

## 7. 自动调谐术语

| 术语 | 含义 |
| --- | --- |
| Baseline Concurrency | 基准卡型或模型的单副本并发基线 |
| KSN Concurrency | 某个 KSN 单 Ready 副本的并发能力 |
| Ready Capacity | Ready 副本数 × 单副本能力 |
| Upper Bound | 按 Ready Capacity、服务实例数和全局上限计算的单实例安全上界 |
| Queue Load Ratio | waiting queue / running queue |
| Probe Fast | 指标良好时按上界的较大步长增并发 |
| Probe Slow | 指标基本良好时按较小步长增并发 |
| Rollback | 成功率或排队恶化时降低并发 |
| Hold | 当前信号不支持调整，保持并发 |

## 8. 常见歧义

### Task failed 与 Request failed

- Request failed：一条输入得到错误结果，通常不会让 Shard 基础设施执行失败。
- Shard failed：Shard 下载、解析、元数据或执行流程本身失败。
- Task failed：初始化失败，或所有 Shard 结束时仍存在无法完成的 Shard 等任务级失败。
- Task completed 可以包含部分 Request failed；最终计数通过 `success_count` 和 `failed_count` 表达。

### Pending 状态与 pending queue

- Task `pending`：分片初始化已经完成，任务等待/正在逐步调度。
- Shard pending queue：具体 Shard 尚未被领取。
- 一个 Task 已经 `running` 时，其剩余 Shard 仍可能位于 pending queue。
