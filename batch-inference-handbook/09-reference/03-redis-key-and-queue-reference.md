# Redis Key 与队列速查

## 1. Shard队列

| Key | 类型 | 内容/生命周期 |
| --- | --- | --- |
| `{model}_pending_queue` | List | 待claim Shard |
| `{model}_process_queue` | List | 在途Shard，成功/失败后LREM |
| `{model}_failed_queue` | List | Shard级失败延迟重试 |
| `upgrade@{fullQueueValue}` | String | process heartbeat，初始TTL 360s |

队列元素把Shard dataset/meta/output Key和join timestamp编码为字符串。诊断工具应复用代码解码器，不要手工按不稳定分隔符拆。

## 2. Task/模型缓存

| Key | 类型 | TTL |
| --- | --- | --- |
| `batch_inference_runtime_task:{taskID}` | String JSON | 60s（普通Task缓存） |
| `batch_inference_model:{modelID}` | String/JSON | 模型缓存逻辑约5min |
| `batch_result_topic_{taskID}` | String `topic@tag` | 168h |

topic/tag直接用`@`拼接，值本身含多个`@`会解码失败；更稳妥是JSON。

## 3. 实时进度

```text
batch_progress:{taskID}:done
batch_progress:{taskID}:failed
batch_progress:{taskID}:snapshot
batch_progress:{taskID}:closed
```

TTL 7天；终态先closed再删除前三个。

## 4. AutoTuner

| Key | 类型 | 含义 |
| --- | --- | --- |
| `batch-inference:model-concurrency-metrics-sample` | String lock | 全局采样锁 |
| `batch-inference:model-concurrency-reconcile` | String lock | 全局调谐锁 |
| `batch-inference:auto-tuner:metrics:{model}:{ksn}` | ZSet | 窗口样本 |
| `batch-inference:auto-tuner:last:{model}` | String JSON | 最近有效决策 |
| `batch-inference:gateway-request-success:v3:{bucket}:{encodedModel}` | Hash | 成功/总请求桶 |

## 5. Task ExecuteOnce

Executor初始化前缀：

```text
batchInference:tasks:lock:{logicalTaskID}
```

逻辑ID包括 `taskSCHEDULE:{taskID}`、`taskStopped:{taskID}`、`taskRunningNotice:{taskID}`。实现使用随机lock value并校验释放，用于一次性状态/通知，不是永久done marker；调用方的TTL和状态CAS仍重要。

## 6. 账号冻结/通知

| Key前缀 | 用途 |
| --- | --- |
| `batch-inference:account-freeze-monitor` | 全局扫描锁 |
| `batch-inference:account-freeze-sms:sent:` | Task通知去重 |
| `batch-inference:account-freeze-sms:pending:` | 客户/项目待聚合Task Set |
| `batch-inference:account-freeze-sms:send-lock:` | 延迟聚合发送锁 |

KIM通知也有独立去重状态，具体以notice实现为准。

## 7. 运维查询原则

- 生产使用只读连接和显式task/model key；
- 禁止 `KEYS *`，使用SCAN或已知key；
- List查看先LLEN，再LRANGE有限范围；
- 不直接DEL process元素，先核对Metadata/heartbeat/执行实例；
- Redis是调度状态，不可仅凭key不存在删除MySQL/OSS；
- 修改前记录类型、TTL、长度和内容hash。

## 8. TTL关系

需要满足：

```text
heartbeat refresh interval < live TTL
upgrade保护期 < 初始 heartbeat TTL
AutoTuner sample lock TTL < sample interval
result topic TTL > 最大Task completion window（或改为持久状态）
closed progress TTL > 最大晚到请求窗口
```

