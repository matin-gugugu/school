# 指标与源码索引

## 1. 主要指标

| 指标 | 说明 | 常用tag |
| --- | --- | --- |
| request_count | 发往Gateway请求 | project/task/model |
| request_fail | 单attempt错误 | model/fail_reason |
| request_final_counter | 最终请求结果 | task/model/req_result |
| request_cost | 单次Gateway耗时 | task/model |
| request_cost_with_retry | 含重试总耗时 | task/model |
| finished_req_counter | WorkPool任务结束 | task/model |
| finish_shard | Shard执行结束 | model/executor_type |
| execute_shard_fail | Shard级失败 | model/fail_reason |
| task_finish | Task完成/失败 | task/task_result |
| upload_shard_failed | Shard结果上传失败 | model/shard_path |
| upload_fail_req_failed | 失败请求上传失败 | model/shard_path |
| oss_task_merge_failed | 最终合并失败 | task/fail_reason |
| db_task_update_failed | 状态更新重试耗尽 | task/event |
| pending/process/failed_queue_counter | 队列长度 | model |
| retry_shard_in_fail_queue | 失败Shard重试 | model |
| time_out_shard_in_fail_queue | 超过重试窗口 | model |
| batch_task_send_result_failed | Kafka结果失败 | task/model |
| model_config_update | 配置写入 | model/source |
| model_goroutine_update | 请求并发变更 | model/old/new |

`fail_reason`直接使用完整错误文本时可能产生高基数，建议增加有限error_class。

## 2. AutoTuner动态指标名

除常量表外，代码直接记录：

```text
model_concurrency_reconcile_fetch_fail
model_concurrency_reconcile_fail
model_concurrency_reconcile_success
gateway_request_success_redis_write_failed
gateway_request_success_redis_missing
gateway_request_success_sample_too_small
kafka_publish_with_retry_failed
```

每轮decision/current/target/upper bound目前主要依赖结构化日志，建议正式指标化/事件化。

## 3. 源码阅读主线

### 启动

```text
scripts/entrypoint.sh
cmd/apiserver/main.go
internal/service/service.go
```

### API/状态

```text
internal/service/apiserver/api_batch/
internal/models/db/batch_task.go
internal/models/db/batch_task_status.go
internal/client/store/msql/store_batch_task.go
```

### TaskCreator

```text
manager/task_creator.go
manager/processor_http_downloader.go
internal/models/shard_metadata.go
pkg/utils/oss_file_utils.go
```

### 调度/执行

```text
scheduler/scheduler.go
scheduler/executor/starter.go
scheduler/queue/
scheduler/executor/executor.go
scheduler/executor/concurrency_controler.go
scheduler/executor/upgrade/
```

### 结果/进度

```text
services/redis/batch_progress.go
services/oss/s3_multipart.go
services/mq/producer.go
internal/models/task_req_result.go
```

### AutoTuner

```text
internal/service/modelconcurrency/
internal/service/gatewaymetrics/request_success_collector.go
internal/scaler/views.go
internal/isvc/
internal/service/apiserver/model_config_service.go
pkg/kconf/model/model_execute_watcher.go
```

## 4. 代码定位原则

函数行号会随提交变化，手册用 `文件:函数名`。离线保存源码时同时保留commit hash；阅读先从entrypoint和调用链，不按目录名猜运行状态。

## 5. 测试重点

已有测试覆盖输入错误分类、AutoTuner信号/多KSN、Gateway成功率、Ready过滤等。建议补齐：

- 20GB级端到端和内存峰值；
- TaskCreator崩溃恢复；
- 跨实例重复Merge；
- 状态机并发终态；
- Kafka丢/重对账；
- `go test -race` Controller/KConf；
- Redis/S3/Gateway故障注入；
- AutoTuner历史replay与震荡检测。
