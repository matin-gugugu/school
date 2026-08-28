# 数据归属与一致性

## 1. 为什么数据分布在三个系统

Batch 推理同时包含：

- 需要事务和长期查询的任务状态；
- 高频、短生命周期的调度与实时进度；
- 可能达到数十 GB 的数据和结果。

单一存储不适合同时承担这些职责，因此采用：

```text
MySQL：控制面持久状态
Redis：运行时协调与实时视图
OSS：大对象数据面与 Shard 元数据
```

## 2. 数据归属表

| 数据 | 权威存储 | 辅助存储/缓存 | 写入方 | 读取方 |
| --- | --- | --- | --- | --- |
| BatchTask 基本信息 | MySQL | Redis Task Cache | API | API、Executor、监控 |
| Task 终态和最终计数 | MySQL | 无 | TaskCreator/Executor | API、通知 |
| 输入源 URL | MySQL InputFile | TaskMessage | API | TaskCreator |
| Shard 数据 | OSS | 无 | TaskCreator | Executor |
| Shard 元数据与状态 | OSS | TaskMetadata 创建快照 | TaskCreator/Executor | Executor/Result Merger |
| 任务 Shard 列表 | OSS TaskMetadata | 无 | TaskCreator | Executor |
| pending/process/failed 队列 | Redis | 无 | Creator/Scheduler/Ender | Scheduler |
| Shard heartbeat | Redis | 无 | Scheduler/Executor | Upgrade Scanner |
| Request 实时进度 | Redis | API 响应临时合并 | Executor | API |
| Shard 结果文件 | OSS | 可选 Kafka 逐条消息 | Executor | Result Merger/下游 |
| 最终结果文件 | OSS | MySQL OutputFile 地址 | Result Merger | 用户/API |
| Message 结果路由 | Redis | TaskMetadata | TaskCreator | Executor |
| 模型执行配置 | KConf | 进程内 Global Config | API/Reconciler | Scheduler/Executor |
| 自动调谐样本 | Redis ZSET | 进程内 fallback | Sampler | Reconciler |

## 3. MySQL

### 3.1 适合保存的内容

- 用户可查询的 Task 生命周期；
- 创建时间、完成窗口和终态时间；
- 输入、输出和错误文件地址；
- 总数、成功数、失败数；
- 项目、模型实例和用户 Metadata。

### 3.2 不保存 Shard 主状态的原因

当前主链路没有为每个 Shard 写 MySQL 表，避免大量 Shard 状态更新增加数据库压力。代价是任务汇总需要读取多个 OSS 元数据对象，事务一致性较弱。

## 4. Redis

### 4.1 队列

Redis List 提供快速原子 claim。process queue 同时承担在途记录和故障恢复索引。

### 4.2 Task Cache

Task 查询采用 cache-aside：

```text
GET Redis Cache
  → 命中：反序列化 BatchTask
  → 未命中：查 MySQL，并异步写缓存，TTL 1 分钟
```

状态更新后异步删除缓存。

### 4.3 实时进度

使用 Set 按 requestID 去重，Hash 保存查询快照。终态时设置 closed key 并删除工作集合，避免迟到请求重新生成进度。

### 4.4 分布式锁和 Once

- Timer 全局锁：确保周期内单实例执行；
- TaskExecutor：确保某 Task 的 running notice、SCHEDULE、stopped 更新只成功执行一次；
- heartbeat：识别升级/宕机遗留的 process Shard。

## 5. OSS

### 5.1 数据对象

OSS 保存：

- `shard_*_data.jsonl`：分片输入；
- `shard_*_meta.json`：分片元数据；
- Shard 输出；
- 失败请求；
- `task_metadata.json`；
- 最终 `results.jsonl`。

### 5.2 Shard 状态更新

Executor 更新状态时采用：

```text
GET shard metadata
→ JSON Unmarshal
→ 修改 status/count/time/error
→ PUT 覆盖 metadata object
```

没有对象版本 CAS。若两个实例同时执行同一 Shard，存在后写覆盖风险；系统主要依赖 Redis claim 和 heartbeat 降低重复执行概率。

## 6. 一致性时间线

正常执行中允许短暂差异：

```text
Request 完成
  → Redis 实时进度立即更新
  → Shard 完成后 OSS 计数更新
  → Task 汇总时 MySQL 计数更新
```

因此读取优先级是：

- 非终态 API：MySQL Task + Redis 实时进度；
- Shard 完成判断：OSS ShardMetadata；
- 终态 API：MySQL 固化值；
- 最终结果内容：OSS Result Object。

## 7. 关键不一致场景

| 场景 | 可能状态 | 当前处理 |
| --- | --- | --- |
| Request 完成后进程退出 | Redis 已计数，Shard 结果可能未写 | Shard 重试；requestID 去重能减少进度重复 |
| Shard 输出已写，Metadata 未完成 | 结果对象存在，Shard 仍 processing/failed | process/failed 恢复可能重新执行 |
| Merge 完成但 DB 未更新 | OSS 有 results，Task 仍 running | 后续完成判断可能再次 merge |
| DB 进入终态后迟到请求上报 | Task completed，Redis 收到旧进度 | closed key 阻止重新累计 |
| KConf 已写，实例尚未刷新 | 配置中心新值、Worker Pool 旧值 | 定期刷新后最终一致 |

## 8. 当前风险与改进方向

### 8.1 Task 创建可靠投递

当前 MySQL 创建后使用本地 goroutine 执行 TaskCreator。进程在入队前退出时，任务可能停留在 init。可引入：

- Transactional Outbox；
- 持久化 Task Creation Queue；
- 真正实现 TaskReconciler 扫描超时 init 任务。

### 8.2 任务进度汇总复杂度

每个 Shard 完成后都读取任务的全部 Shard Metadata。S 个 Shard 最坏约产生 O(S²) 次元数据读取。可改为 Redis/DB 原子 Shard 完成计数，并在计数达到 S 时触发一次 merge。

### 8.3 Merge 多实例幂等

当前 `outputLock` 是进程内锁。多副本可能同时判断完成并合并。可增加：

- Redis `merge:{taskID}` 分布式锁；
- MySQL `running → merging → completed` CAS；
- 结果对象 metadata 幂等检查；
- merge generation/version。

### 8.4 Shard Metadata CAS

可使用 S3 ETag/If-Match 或将 Shard 主状态迁移到具备条件更新能力的数据库，防止并发覆盖。

## 9. 面试表达

可以这样概括数据架构：

> 我们按照数据访问特征拆分存储：MySQL 保存任务级权威状态，Redis 承担高频调度、分布式锁和实时进度，OSS 保存大文件、Shard 元数据及最终结果。运行态采用最终一致性，通过 requestID 去重、状态条件更新、process queue 和终态 closed marker 控制重复与迟到写入。
