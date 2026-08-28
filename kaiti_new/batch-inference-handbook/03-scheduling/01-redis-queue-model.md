# Redis 队列模型

## 1. 为什么按模型建队列

不同模型的吞吐、资源规模和请求时延不同。如果所有 Shard 共用一个全局队列：

- 慢模型可能占满执行器；
- 无法按模型配置最大 Shard 和请求并发；
- 新模型或缩容模型难以单独停流；
- 自动调谐结果无法直接作用到队列消费。

因此队列以 `model_service_name` 为一级分区。

## 2. 三类队列

```text
{modelName}_pending_queue
{modelName}_process_queue
{modelName}_failed_queue
```

| 队列 | 进入条件 | 离开条件 | 主要作用 |
| --- | --- | --- | --- |
| pending | TaskCreator 完成 Shard | Scheduler claim | 等待首次执行 |
| process | 从 pending 原子迁移 | Executor 执行结束 | 记录在途 Shard，支持宕机恢复 |
| failed | Shard 执行单元返回错误 | 达到重试时间后 LPOP | 延迟重试 |

## 3. 队列元素

```text
modelName#shardDatasetKey#shardMetadataKey#shardOutputKey#joinTimestamp
```

字段：

| 字段 | 用途 |
| --- | --- |
| modelName | 选择模型 Worker Pool、失败队列和指标标签 |
| shardDatasetKey | 下载输入 JSONL |
| shardMetadataKey | 读取/覆盖 Shard 状态 |
| shardOutputKey | 保存结果和解析 TaskID |
| joinTimestamp | 判断失败重试延迟和最大容忍时间 |

`joinTimestamp` 在首次加入 pending 时生成，失败重入队时不会刷新。因此最大失败窗口是相对首次入队时间，而不是相对最近一次失败。

## 4. 基础操作

### 4.1 入队

```text
RPUSH queue shardValue
```

入队带固定三次重试，每次失败后等待两秒。

### 4.2 普通出队

```text
LPOP queue
```

Redis Nil 被转换为空字符串，表示队列为空。

### 4.3 队列间迁移

普通 process 调度不是先 LPOP 再单独 RPUSH，而是一个 Lua 脚本完成：

```lua
local element = redis.call('LPOP', pending)
if element then
    redis.call('RPUSH', process, element)
    redis.call('SET', 'upgrade@' .. element, '1', 'EX', heartbeatTTL)
    return element
end
return nil
```

它保证不会出现：

```text
已经从 pending 删除
但进程在写 process 前退出
导致 Shard 永久丢失
```

## 5. Redis List 上构建 ACK 语义

Redis List 没有 Kafka/RabbitMQ 的消费 ACK。系统自行实现：

```text
pending  = 未领取
process  = 已领取但未 ACK
LREM process = ACK/执行结束
upgrade heartbeat = 消费者仍存活
```

成功或失败执行结束后，Executor 都会从 process queue 移除原元素；失败项再由 Ender 写入 failed queue。

## 6. 多实例语义

所有服务副本都运行 Scheduler，但 Lua claim 对单个 Redis 实例是原子的，因此一个 pending 元素只能被一个副本迁移。

这解决的是“领取唯一性”，并不等于严格 exactly-once：

- 实例可能在 Gateway 成功后、写结果前退出；
- heartbeat 过期后另一个实例会重新执行 Shard；
- OSS 元数据更新没有 CAS；
- 下游模型请求不一定具备业务幂等。

系统整体更接近：

```text
Shard at-least-once execution
+ request/result ID 去重与状态保护
```

## 7. 队列发现

Scheduler 不扫描 Redis Key，而是从 KConf 的 `model_config.models` 获取模型名列表，然后拼接队列名。

影响：

- 未进入 KConf 的模型即使有 pending queue，也不会被调度；
- 从 KConf 移除模型后，其剩余队列可能滞留；
- Go map 转 slice 的顺序不稳定，当前模型遍历不代表稳定优先级。

因此私有模型二阶段资源池调度设计明确提出：不能用当前 map 遍历顺序表达行业优先级。

## 8. 队列指标

服务周期记录每模型：

- pending queue length；
- process queue length；
- failed queue length；
- running Worker 数；
- running Shard 数。

这些指标用于告警、排障和容量调谐，但自动调谐使用的 waiting/running queue 主要来自推理 Scaler，而不是 Batch Redis 队列长度。

## 9. 当前风险

### 9.1 载荷编码

载荷使用 `#` 拼接，没有结构版本和转义。模型名或 Key 包含 `#` 时解析失败。更稳妥的方案是 JSON/MessagePack 或 Redis Hash + 只在 List 保存 ShardID。

### 9.2 无队列级死信记录

failed 元素超过最大重试窗口后会被丢弃并记录指标，但没有独立 Dead Letter Queue 供人工回放。

### 9.3 process queue 扫描

升级恢复通过 `LRANGE 0 -1` 读取整个 process queue。大队列可能带来 Redis 和网络开销。

## 10. 面试表达

> 调度采用每模型三队列。领取时通过 Lua 把 Shard 从 pending 原子迁移到 process，并写 heartbeat；process 相当于自建的未 ACK 队列。正常结束后 LREM，Shard 级失败再进入 failed queue。这样支持多个服务副本并发消费和实例宕机恢复，但语义仍然是 at-least-once，需要结果幂等配合。

## 11. 源码定位

- `scheduler/queue/base_queue.go`
- `scheduler/queue/pending_queue.go`
- `scheduler/queue/process_queue.go`
- `scheduler/queue/failed_queue.go`
- `scheduler/queue/queue_controller.go`
- `scheduler/queue/helper.go`
