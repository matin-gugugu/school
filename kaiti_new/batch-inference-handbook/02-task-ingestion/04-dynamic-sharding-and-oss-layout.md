# 动态分片与 OSS 布局

## 1. 分片目标

分片同时服务于四个目标：

1. 避免单任务文件整体进入内存；
2. 允许多个 Shard 并行执行；
3. 限制单个失败单元的重试成本；
4. 避免小文件产生过多 Shard 和调度开销。

## 2. 分片大小计算

第一次校验得到总行数 `N` 后：

```text
if N <= maxShardNumber × minShardSize:
    linePerShard = minShardSize
else:
    linePerShard = ceil(N / maxShardNumber)
```

等价理解：

- 小任务每个 Shard 至少有 `minShardSize` 行；
- 大任务通过增大 Shard 行数，把 Shard 数控制在 `maxShardNumber` 左右。

### 2.1 当前配置覆盖语义

如果 `max_line_per_shard > 0`，当前代码直接执行：

```text
linePerShard = max_line_per_shard
```

字段名看起来像“上限”，但实现是“固定覆盖值”。因此不能把当前行为描述成 `min(calculated, maxLinePerShard)`。

代码快照中的示例配置：

```yaml
min_shard_size: 20
max_shard_number: 100
max_line_per_shard: 5000
```

在该配置下实际每个完整 Shard 使用 5000 行，动态公式会被覆盖。

## 3. 分片创建流程

```text
currentShard = bytes.Buffer
currentLines = 0
totalLines = 0
shardIndex = 0
startLine = 0

for each JSONL line:
    validate JSON object
    unmarshal BatchRequest
    request.ID = "batch-" + UUID
    marshal request
    append line + '\n' to currentShard
    currentLines++
    totalLines++

    if currentLines >= linePerShard:
        upload shard data
        upload shard metadata
        append metadata to shard list
        reset buffer/counters

upload final non-empty shard
upload task metadata
enqueue all shards
```

## 4. 内存边界

当前输入侧不是每行直接 Multipart 上传，而是一个 Shard 使用 `bytes.Buffer` 累积后 `PutObject`。

内存上界近似：

```text
currentShardBytes
≈ linePerShard × averageSerializedLineBytes
```

极端理论值还受 `max_jsonl_line_bytes` 影响：如果允许 5000 行且每行接近 10MiB，单 Shard 内存会不可接受。因此生产配置必须结合实际平均/高分位行大小，而不是只看行数。

可以演进为：

- 按字节和行数双阈值切分；
- Shard 自身也使用 Multipart 或 Pipe 流式上传；
- 统计 P95/P99 行大小动态设置行数。

## 5. OSS 对象布局

```text
tasks/{taskID}/
├── task_metadata.json
├── shards/
│   ├── shard_0000_data.jsonl
│   ├── shard_0000_meta.json
│   ├── shard_0001_data.jsonl
│   ├── shard_0001_meta.json
│   └── ...
└── output/
    ├── results.jsonl
    ├── shards/
    │   ├── shard_0000_data.jsonl
    │   └── ...
    └── failed/
        ├── shard_0000_failed_reqs.jsonl
        └── ...
```

### 5.1 Key 规则

| 对象 | Key |
| --- | --- |
| Shard 输入 | `tasks/{taskID}/shards/shard_{index:04d}_data.jsonl` |
| Shard 元数据 | `tasks/{taskID}/shards/shard_{index:04d}_meta.json` |
| Task 元数据 | `tasks/{taskID}/task_metadata.json` |
| Shard 输出 | `tasks/{taskID}/output/shards/shard_{index:04d}_data.jsonl` |
| 失败请求 | `tasks/{taskID}/output/failed/shard_{index:04d}_failed_reqs.jsonl` |
| 最终结果 | `tasks/{taskID}/output/results.jsonl` |

## 6. 元数据写入顺序

单 Shard：

```text
上传 shard data
→ 上传 shard metadata
→ 将 metadata 加入内存 shard list
```

全部 Shard：

```text
上传 task_metadata
→ 依次将 Shard 加入 pending queue
→ 发送 pending notice
→ MySQL Task init → pending
```

`Risk`：入队不是一个全局事务。若部分 Shard 入队成功、后续 Shard 入队失败，TaskCreator 会把 Task 标记 failed，但已经入队的 Shard 仍可能被 Executor 领取。Executor 当前不会把 failed Task 作为通用 abort 条件，只特殊处理 expired/stopped，因此可能继续产生无效执行。改进时应增加 Task 状态 gate 或批量入队原子化。

## 7. Shard 队列值

每个 pending 元素：

```text
{modelServiceName}
#{shardDatasetKey}
#{shardMetadataKey}
#{shardOutputKey}
#{joinUnixTimestamp}
```

示意：

```text
model-a#tasks/bt-1/shards/shard_0000_data.jsonl#tasks/bt-1/shards/shard_0000_meta.json#tasks/bt-1/output/shards/shard_0000_data.jsonl#1720000000
```

加入时间用于 failed queue 延迟重试和最大重试窗口判断。载荷采用 `#` 拼接，依赖模型名和 OSS Key 不包含 `#`。

## 8. Message 结果路由

如果：

```text
provide_method == "message"
且 result_topic 非空
```

TaskCreator 写入：

```text
key   = batch_result_topic_{taskID}
value = {resultTopic}@{tag}
TTL   = 168 hours
```

随后 TaskMetadata 也保存 ProvideType、ResultTopic 和 Tag。

## 9. 分片校验不变量

创建结束后计算：

```text
Σ shard.TotalLines == totalLines
```

当前不一致时只记录日志，不阻止任务继续。更严格实现应把它作为初始化失败，避免最终计数永远无法完成。

## 10. 性能取舍

| Shard 较小 | Shard 较大 |
| --- | --- |
| 并行度高 | 调度和元数据对象少 |
| 单次失败重试成本低 | 顺序扫描和上传更高效 |
| Redis/OSS 操作数量多 | 单 Shard 内存更高 |
| 最终完成汇总元数据读取多 | 长尾 Shard 更明显 |

实际调优应联合考虑：平均行大小、单请求延迟、目标并发、OSS QPS、任务完成窗口和失败概率。

## 11. 面试表达

> 动态分片不是单纯按固定文件大小切割。系统先流式统计总行数，根据最小 Shard 大小和最大 Shard 数计算目标行数，再按配置覆盖。分片时内存只保存当前 Shard，并把数据、Shard 元数据和 Task 元数据写入 OSS。这样可以在控制调度对象数量的同时，把 20GB 总文件的内存占用限制在单 Shard 范围。

## 12. 源码定位

- `manager/task_creator.go: executeDatasetSharding`
- `manager/task_creator.go: getShardSize`
- `manager/task_creator.go: createShardsOnce`
- `manager/task_creator.go: uploadShard`
- `pkg/utils/oss_file_utils.go`
- `internal/models/s3_metadata.go`
