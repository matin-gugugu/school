# OSS 对象与 Kafka 事件速查

## 1. OSS 目录

```text
tasks/{taskID}/
├── task_metadata.json
├── shards/
│   ├── shard_0000_data.jsonl
│   ├── shard_0000_meta.json
│   └── ...
└── output/
    ├── shards/
    │   ├── shard_0000_data.jsonl
    │   └── ...
    ├── failed/
    │   ├── shard_0000_failed_reqs.jsonl
    │   └── ...
    └── results.jsonl
```

所有路径确定性，序号4位补零。

## 2. 对象含义

| 对象 | 内容 | 写者 | 读者 |
| --- | --- | --- | --- |
| task_metadata | Shard manifest/总行数 | TaskCreator | Executor汇总/Merge |
| shard_data | 加平台requestID后的输入 | TaskCreator | Executor |
| shard_meta | 范围、状态、计数、模型路由 | TaskCreator/Executor | Scheduler/汇总/Merge |
| shard_output | BatchResponse JSONL | Executor | 最终Merge/补发 |
| failed_reqs | 原始失败请求JSONL | Executor | 人工/自动重提 |
| results | 全量有序结果 | Multipart Merge | 用户/API |

## 3. 最终对象metadata

```text
task_id
total_lines
success_count
failed_count
merge_time
```

既用于审计，也用于Complete响应不确定时确认远端对象已成功。

## 4. Kafka：Task Notice

由 `notice.SendTaskNoticeMsg` 发送 Running/Finish/Failed/Expired 等事件。Running有Task级ExecuteOnce；不同终态路径也可能发送KIM。

消费端应明确Finish是“计算结束”还是“结果ready”；当前代码存在Merge前发送Finish的窗口。

## 5. Kafka：逐请求结果

统一中转Topic的 TaskReqResult：

```text
task_id
time
model_service_name
tag
result_topic
batch_response
```

下游按 result_topic/tag路由。生产端逐条最多5次，无事务outbox。

## 6. Kafka：Gateway perflog

AutoTuner Consumer只读取指定router request_cost指标，筛选offline/Sheddable，按模型和30秒桶写Redis：

- 2xx success；
- 429/5xx capacity failure；
- 其他状态忽略。

Consumer group保证分区分配，但Kafka重投可能重复HINCRBY；比率通常影响小，严谨方案需使用offset幂等或流处理框架。

## 7. 数据保留与清理

当前手册未发现完整的OSS生命周期/Task删除联动实现。应定义：

- 输入Shard、失败文件、最终结果各自保留期；
- failed/stopped/expired Task是否保留部分结果；
- Multipart未完成会话清理；
- Delete API是否只软删DB还是同时异步删对象；
- 合规擦除与审计。

## 8. 数据安全

- Bucket/Key可以记录，下载凭证和预签名query不可记录；
- Server-side encryption、IAM最小权限和审计由部署配置保障；
- Task Metadata含项目、模型和可能的业务标识，应按敏感数据处理；
- failed request文件保存原始输入，风险通常高于模型响应。

