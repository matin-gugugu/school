# 故障恢复矩阵与卡任务排查

## 1. 通用排查顺序

```text
MySQL Task状态/时间/计数
  → Task Metadata与Shard清单
  → 每Shard Metadata状态
  → 模型pending/process/failed队列
  → process heartbeat
  → Gateway/Ready/账号状态
  → Shard结果与最终结果对象
  → Kafka/通知指标
```

不要只看一个 Redis 队列。MySQL 是 Task 控制状态，OSS Metadata 是 Shard/结果事实，Redis 是调度和实时视图，必须交叉验证。

## 2. 故障矩阵

| 现象 | 可能原因 | 当前恢复 | 人工/后续动作 |
| --- | --- | --- | --- |
| 长期 init | API进程在goroutine前退出；输入校验卡住 | 无通用Reconciler | 查创建日志/Task Metadata，安全重触发或失败 |
| pending且pending queue有元素 | 模型无调度容量/配置缺失 | Scheduler周期扫描 | 查模型配置、Shard counter、服务实例 |
| pending但所有队列无元素 | 部分入队失败/控制状态丢失 | 无可靠兜底 | 用Task Metadata重建未完成Shard队列 |
| running且process有元素 | 正常执行或Ready等待 | heartbeat续期 | 查heartbeat、Ready KSN、请求进度 |
| process有元素无heartbeat | 实例退出/升级 | 开启silky upgrade后恢复 | 确认保护期后重执行 |
| failed queue增长 | Shard级基础设施故障 | 时间窗口后重试 | 按fail reason修复OSS/模型/账号 |
| 请求失败率高 | 429/529/5xx、并发过高 | 请求重试+AutoTuner回退 | 查成功率/queue ratio/目标并发 |
| 实时进度不动 | 请求没完成或Redis上报失败 | Shard完成后MySQL纠正 | 查WorkPool、Gateway、progress keys |
| 全Shard completed但Task running | Merge失败/重复触发竞态 | 当前仅指标，无自动恢复 | 重试Merge并补状态；实现Reconciler |
| Task completed但文件不完整 | Message模式只合并一个Shard/对象覆盖 | 无 | 按Shard结果重建，明确交付契约 |
| completed但消息缺失 | Kafka异步发送失败/进程退出 | producer最多5次 | 从OSS Shard结果补发并幂等 |
| 取消后仍有请求 | 60秒缓存、无Task cancel context | 请求边界最终看到状态 | invalidate/广播cancel，核对计费 |
| expired仍有process元素 | 终态与队列未清理 | 请求执行时停止 | 清理/消费残留，closed防进度重建 |

## 3. init 卡住

检查：

1. DB 中 created_at 是否已远超正常分片耗时；
2. 是否存在 `tasks/{taskID}/task_metadata.json`；
3. 是否已有部分 `shard_*_data/meta`；
4. TaskCreator 日志是否有 JSONL、网络中断、单行过大；
5. pending queue 是否已有部分 Shard。

安全恢复必须避免对已入队 Shard重复生成新 request ID。最佳方式是基于已有 manifest 补齐；不要盲目重新跑整套 createShards。

## 4. pending 卡住

```text
LLEN {model}_pending_queue
LLEN {model}_process_queue
LLEN {model}_failed_queue
```

再检查：

- 模型是否在 KConf model list；
- `max_execute_shard` 运行时实际值；
- 进程内 Shard Counter 是否异常不归零；
- Scheduler interval和服务健康；
- 模型名是否与入队时一致；
- private/public pool过滤是否正确。

## 5. running 卡住

按 Shard 定位：

- Metadata processing：看 process queue 和 `upgrade@{queueValue}` TTL；
- heartbeat持续：执行实例还活着，可能等Ready或某个长请求；
- heartbeat消失：等保护期/升级扫描；
- Redis实时 completed持续增加：正常慢任务；
- 完全不增：查模型 WorkPool running、Gateway timeout、Ready等待日志。

Task completion window 到期只在请求边界被发现；Ready的Background等待可能拖延，应特别关注。

## 6. failed queue

要区分：

- Request 失败：写在结果中，Shard可completed，不进failed queue；
- Shard 失败：下载/模型/Ready/账号等流程错误，进入failed queue；
- 超过最大retry window：元素不再重入队，无DLQ。

需要从日志拿首次 join timestamp和最新 err，因为队列元素没有 attempt/lastError字段。

## 7. Merge 卡住/失败

确认：

1. Task Metadata `TotalLines`；
2. 所有 Shard Metadata 是否 completed且计数和相等；
3. 每个 Shard output对象是否存在、大小合理；
4. 最终 `results.jsonl` 是否已存在；
5. 对象 metadata是否匹配 task_id/counts；
6. `oss_task_merge_failed` 指标与日志；
7. 是否有残留 Multipart upload。

若最终对象已存在且 metadata正确但DB仍running，可在校验后补 `RUN_COMPLETE`。人工合并必须保留Shard顺序、换行、计数并记录审计；不要使用含长期有效签名的公开文档传递结果。

## 8. AutoTuner 不生效

检查：

- 全局/单模型开关；
- per_instance_concurrency是否存在；
- 模型是否有pending/running Task；
- ISVC Runtime是否匹配model/KSN/pool且Ready>0；
- Scaler View是否唯一 active；
- Gateway样本是否达到100；
- ZSET窗口是否有样本；
- KConf Update是否失败；
- Watcher是否收到变更；
- WorkPool cap检查任务是否执行；
- 全局锁是否长期占用。

## 9. 恢复操作原则

- 先只读确认对象和状态，再修改；
- 以 taskID/shardIndex明确目标，禁止批量模糊清理；
- 重放前确认 Gateway/Kafka 下游幂等；
- 手工修改DB必须同时处理缓存和Redis实时进度；
- 手工结果必须写确定性/审计路径，不覆盖原始证据；
- 记录操作人、原因、前后状态和对象 ETag。

