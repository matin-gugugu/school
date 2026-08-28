# Batch Inference 快速复习

## 1. 一句话

JSONL批任务经流式校验/动态分片进入S3和Redis模型队列，Executor按Shard/Request两级并发调用LLM Gateway，Redis提供实时进度，最终用S3 Multipart有序合并；AutoTuner按Ready容量上界和成功率/队列反馈热调模型WorkPool。

## 2. 两条主闭环

```text
任务闭环
API → MySQL init → HTTP JSONL校验/计数 → 二次下载分片
→ S3 data/meta → Redis pending → Lua claim process
→ Executor/Gateway → Redis progress + S3 result
→ 全Shard汇总 → Multipart results.jsonl → MySQL completed
```

```text
容量闭环
ISVC Ready/卡型 → 物理上界
Gateway 2xx/429/5xx + Scaler waiting/running → 决策
→ KConf max_execute_goroutine → Watcher → WorkPool cap
→ 新运行指标
```

## 3. 运行时真相

- 镜像只启动apiserver；
- apiserver进程内同时启动API、TaskCreator、Scheduler、Executor、AutoTuner、监控；
- 多副本单体编排，不是README意义上的独立Manager/Scheduler微服务；
- 独立scheduler、TaskProcessorV2、Statemanager、TaskReconciler是历史/未装配。

## 4. 数据归属

| 系统 | 角色 |
| --- | --- |
| MySQL | Task持久状态、计数、input/output定位 |
| Redis | pending/process/failed、锁、heartbeat、缓存、实时进度、调谐窗口 |
| S3 | Shard输入/Metadata/结果、失败请求、最终JSONL |
| Kafka | Task通知、逐请求结果、Gateway perflog |
| KConf | 每模型Shard/Request并发和单副本容量 |

## 5. 20GB链路

```text
pass1：流式validate+count
pass2：流式assign requestID+按行切Shard
execute：一个Shard requests/results驻内存
merge：按Shard顺序扫描，64MiB buffer满即UploadPart
```

动态公式：

```text
lines = N <= maxShards×minLines ? minLines : ceil(N/maxShards)
```

但 `max_line_per_shard>0` 会直接覆盖公式。

准确空间边界：接入O(Shard)，执行O(Shard requests+responses)，最终合并O(64MiB+当前行)，不是全链路O(1)。

Multipart：64MiB/Part，最多10000；小于64MiB直接Put；Complete错误后用task/count/merge_time metadata确认远端是否已完成。

## 6. Redis调度

```text
{model}_pending_queue
{model}_process_queue
{model}_failed_queue
upgrade@{queueValue}
```

Lua原子 pending LPOP → process RPUSH + heartbeat。明确Shard失败进failed延迟重试；实例退出时heartbeat过期后孤儿恢复。语义at-least-once。

## 7. 两级并发

- `max_execute_shard`：单进程每模型同时驻留/执行Shard；
- `max_execute_goroutine`：单进程每模型请求WorkPool；
- Runtime对<=0分别回退5和10，0不能暂停；
- Controller map当前无显式锁，有data race风险。

## 8. Gateway执行

- OpenAI-compatible Chat Completions；
- body.model被运行时ModelServiceName覆盖；
- stream请求在服务端聚合为完整结果，不实时回用户token；
- 固定 `Sheddable` 调度优先级；
- Ready等待5/10/20/40/60秒，首次用Background可能无限等待；
- 可重试：429、529、500-505；
- backoff=min(base×2^attempt,max)，无jitter、sleep不响应cancel。

## 9. 进度与结果

实时进度：done/failed Set按稳定requestID去重，Lua写snapshot；终态先closed再删集合，API终态回MySQL。

Task完成：每Shard结束全扫所有Metadata，成功行数覆盖总行数后Merge；存在failed且无在途则Task failed。

主要问题：全扫是O(S²)；多个最后Shard可能重复Merge；outputLock仅进程内；Merge失败只打点、Task可能卡running。

文件结果有序；Kafka消息无序且可能丢/重。Message模式最终文件当前只合并第一Shard。

## 10. AutoTuner公式

```text
perReplica = floor(baseline × cardRatio)
ksnCapacity = readyReplicas × perReplica
upperBound = clamp(ceil(ΣeffectiveCapacity × safety / batchInstances), 1, max)
```

默认信号：

```text
success < .990 bad; > .995 good; else ok
queue waiting/running > 1 bad; < .4 good; else ok
```

决策：

```text
任一bad → rollback -10% upperBound
good+good → fast +5%
good+ok / ok+good → slow +2%
其他 → hold
missing → 排除KSN及其capacity
```

多KSN优先级：rollback > hold > slow > fast。

默认30秒采样、10分钟窗口、5分钟调节、Gateway最小100请求；只统计Sheddable离线流量，2xx成功、429/5xx失败，其他4xx排除。

## 11. 简历结果

`Experience Result`：

- 20GB单文件；
- 容量相关失败率12.1%→1.8%，下降10.3个百分点/约85.1%；
- KV Cache平均利用率37%→71%，+34个百分点/约91.9%；
- KV Cache当前是效果指标，不是控制器输入。

## 12. 最重要风险

1. DB创建后TaskCreator只在本地goroutine，可能永久init；
2. Merge失败无状态补偿，可能永久running；
3. 状态更新未统一检查RowsAffected，FAIL/RUN_COMPLETE无条件；
4. OSS Metadata last-write-wins，无attempt/CAS；
5. Shard恢复可能重复Gateway调用和计费；
6. Kafka无outbox，可能丢/重；
7. 部分Shard入队后失败可能继续执行；
8. 完整Config/运维链接存在敏感信息泄漏风险。

优先改进：create outbox → merging状态+per-task分布式锁/重试 → Task Reconciler → 增量Reducer → 有界Shard pipeline → Kafka outbox。

## 13. 三句边界

> 20GB依赖流式接入和固定Part合并，但执行仍以单Shard为内存边界。

> 调度和恢复是at-least-once，稳定ID/确定性Key缓解重复，但不等于端到端exactly-once。

> 私有模型任务窗口是Designed；当前线上运行形态和已实现AutoTuner必须与它分开讲。

## 14. 面试前阅读

1. `10-experience-and-interview/01-project-summary.md`
2. `02-large-file-chain-star.md`
3. `03-autotuner-star.md`
4. `04-interview-question-bank.md`
5. `07-reliability/03-failure-recovery-matrix.md`
