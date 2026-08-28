# 当前平台能力地图

## 1. `Implemented` 能力

| 能力 | 关键实现 |
| --- | --- |
| Batch任务管理 | Create/Get/List/Timeout/Cancel/Delete API |
| public/private模型解析 | 按scope查询模型实例和项目 |
| HTTP JSONL输入 | HEAD+GET、连接/首包/读空闲超时 |
| 大文件处理 | 流式扫描、动态分片、OSS中间结果 |
| 模型级调度 | Redis pending/process/failed队列 |
| 多实例claim | Lua原子pending→process |
| 两级并发 | 模型Shard limit + Request WorkPool |
| Gateway执行 | OpenAI-compatible chat，stream聚合 |
| 请求重试 | 429/529/500-505指数退避 |
| 升级恢复 | process heartbeat与孤儿Shard重做 |
| 实时进度 | Redis requestID去重snapshot |
| 文件交付 | Shard JSONL+S3 Multipart最终合并 |
| 消息交付 | Kafka逐请求结果和Task Notice |
| 账号冻结 | 提交前/attempt前/周期扫描+通知 |
| 并发自动调谐 | Ready容量+成功率+队列负载闭环 |
| 配置管理 | 手动API/Reconciler统一写KConf、热更新 |

## 2. API 面

当前 `/v1` 提供：

```text
POST   /batches
GET    /batches?batch_ids=...
GET    /batches/:batch_id
POST   /batches/:batch_id/timeout
POST   /batches/:batch_id/cancel
DELETE /batches/:batch_id

POST   /models/config
GET    /models/:model_name/config
GET    /models/config
```

另有 test model worker接口，应视为调试/兼容入口，不作为正式产品能力重点。

## 3. 输入/输出模式

输入的主执行路径实际使用 `input_file.info.url` 做 HTTP 下载。请求结构也有 bucket/key，但 TaskCreator 当前不直接按 bucket/key下载。

输出支持：

- file：最终OSS JSONL；
- message：每请求Kafka结果，OSS仍保留Shard结果；
- Task lifecycle notices；
- failed request JSONL。

## 4. 模型范围

public/private模型都能进入 Batch 链路。差异主要在：

- 模型实例查询来源和 model_project_id；
- Ready KSN 对资源池的过滤；
- private 模型允许非offline pool；
- 并发采样需要识别 private model service。

## 5. 控制面与数据面

```text
控制面：API、MySQL状态、KConf、AutoTuner、通知
数据面：HTTP JSONL、OSS Shard、Redis队列、Gateway请求、Kafka结果
```

当前两者在同一个 apiserver 进程中运行。这减少部署组件，但故障域较大；未来拆分前应先把 TaskCreator 触发、状态变化和结果交付变成 durable event。

## 6. 运维能力

- KConf动态模型配置；
- 队列长度与执行计数指标；
- silky upgrade恢复；
- 任务超时时间延长；
- 欠费自动终止与SMS/KIM；
- AutoTuner全局/单模型开关；
- 手动模型并发更新。

当前缺少正式的 Task重放、Merge补偿、消息补发、DLQ和统一管理后台接口。

## 7. 能力边界

- 执行协议集中在 Chat Completions，不是任意endpoint代理；
- Task创建异步处理不是durable；
- 取消响应不代表所有在途请求立刻停止；
- 文件Task结果有序，消息到达顺序不保证；
- Request部分失败时Task仍可completed；
- 20GB是实践验证，执行内存边界仍是单Shard；
- 自动调谐只改变Request并发，不自动改变Shard并发。

