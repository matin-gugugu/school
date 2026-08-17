# 组件与代码地图

本文用于在有源码时定位实现，也用于在没有源码时确认模块边界。当前主链路从 `cmd/apiserver` 和 `internal/service/Service.Start` 开始，而不是从目录名称推断。

## 1. 当前装配的核心组件

| 组件 | 职责 | 关键入口 | 状态 |
| --- | --- | --- | --- |
| API Server | Batch 和模型配置 HTTP API | `cmd/apiserver/main.go` | Implemented |
| Service Bootstrap | 初始化依赖、HTTP、Timer 和后台循环 | `internal/service/service.go` | Implemented |
| Proxy Context | Store、Kafka、S3、Gin 依赖容器 | `internal/proxy/context.go` | Implemented |
| Batch API | 创建、查询、超时、取消、删除 | `internal/service/apiserver/api_batch` | Implemented |
| TaskCreator | 下载、校验、分片、上传、入队 | `manager/task_creator.go` | Implemented |
| Dataset Reader | HTTP 超时、断流状态和完整性识别 | `manager/processor_http_downloader.go` | Implemented |
| Redis Queue | pending/process/failed 队列 | `scheduler/queue` | Implemented |
| Scheduler | Starter → Execute → Ender | `scheduler/scheduler.go` | Implemented |
| Executor | Shard 与 Request 执行 | `scheduler/executor/executor.go` | Implemented |
| ConcurrencyController | 每模型 Worker Pool 和 Shard 上限 | `scheduler/executor/concurrency_controler.go` | Implemented |
| OSS Service | S3 Put/Get/List/Multipart | `services/oss` | Implemented |
| MySQL Store | BatchTask CRUD 与状态转换 | `internal/client/store/msql` | Implemented |
| Redis Progress | 请求级实时完成/失败计数 | `services/redis/batch_progress.go` | Implemented |
| Model Cache | 模型 OpenAPI 查询与五分钟缓存 | `internal/service/modelcache` | Implemented |
| ISVC Client | Ready 副本、卡型、Pool | `internal/isvc/ready.go` | Implemented |
| Scaler Client | waiting/running 和成功率指标 | `internal/scaler/views.go` | Implemented |
| Auto Tuner | 指标窗口、信号、容量和 KConf 闭环 | `internal/service/modelconcurrency` | Implemented |
| Gateway Metrics | Kafka perflog 成功率聚合 | `internal/service/gatewaymetrics` | Implemented |
| Account Freeze | 执行前和周期性冻结检查 | `internal/service/accountfreeze` 等 | Implemented |
| Notice | Kafka 任务状态、KIM、SMS | `pkg/notice` | Implemented |

## 2. 关键目录关系

```text
cmd/apiserver
  └── internal/service
      ├── internal/proxy
      │   ├── internal/client/store/msql
      │   ├── services/mq
      │   └── services/oss
      ├── manager/TaskCreator
      ├── scheduler/Scheduler
      │   ├── scheduler/queue
      │   ├── scheduler/executor
      │   └── scheduler/statistics
      ├── internal/service/modelconcurrency
      ├── internal/service/gatewaymetrics
      └── internal/service/accountfreeze
```

## 3. 核心调用关系

### 3.1 任务创建

```text
Batch.CreateBatch
  → Store.GetModelInstanceByModelInstanceIdAndScope
  → Store.CreateBatchTask
  → goroutine TaskCreator.CreateTask
      → validateDataset
      → executeDatasetSharding
          → createShardsOnce
          → uploadShard/uploadTaskMetadata
          → enqueueShards
      → UpdateBatchTaskByIdWithEvent(INIT_SUCCESS/INIT_FAIL)
```

### 3.2 Shard 调度与执行

```text
Service Timer
  → Scheduler.ScheduleExecutor
      → Executor.StarterExec
          → FindIdleShardTask
          → pending 原子迁移到 process
      → Executor.Execute
          → processShard
              → processShardData
                  → WorkPool.Submit(funcCall)
                      → handleRequest
      → Executor.EnderExec
          → 失败项加入 failed queue
```

### 3.3 结果完成

```text
processShard
  → completeShardWithOutput
  → saveResults
  → reportBatchProgress
  → updateTaskProgress
      → 读取 task_metadata
      → 读取所有 shard metadata
      → 未完成: PROGRESS
      → 全部失败终结: FAIL
      → 全部有结果: outputTaskResultFileAndUpdateStatus
          → MergeShardOutputs
          → RUN_COMPLETE
```

### 3.4 自动调谐

```text
SampleAutoTunerMetricsOnce
  → Scaler.ListModelViews
  → ISVC.FetchRuntimeInfoMap
  → 筛选 active task model
  → Redis ZSET 写入 KSN 样本

ReconcileOnce
  → ISVC Ready 容量
  → averageAutoTunerMetrics
  → Gateway success rate 覆盖引擎成功率
  → EvaluateConcurrencySignal
  → AggregateAutoTuneDecision
  → ApplyModelConfigUpdates
  → KConf Watcher
  → ConcurrencyController.Update
```

## 4. 遗留和未装配代码

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| `cmd/scheduler` | Legacy/Unwired | 存在入口，但容器未启动，且缺少显式 Redis 初始化 |
| `pkg/taskprocessor` | Legacy | Kafka 驱动的旧分片处理器，当前没有启动调用 |
| `pkg/statemanager` | Legacy | 文件主体被注释，不参与当前状态更新 |
| `pkg/controller/taskreconciler` | Stub | 只有 Timer 和 TODO，没有恢复逻辑 |
| `services/oss/batch_inference_service.go` | Legacy | 旧的 BatchInferenceOSS 代码被注释 |
| 私有模型任务窗口调度 | Designed | 有阶段二设计文档，尚未进入当前执行 gate |

## 5. 阅读代码的推荐顺序

1. `scripts/entrypoint.sh`
2. `cmd/apiserver/main.go`
3. `internal/service/service.go`
4. `internal/service/apiserver/api_batch/api_batch.go`
5. `manager/task_creator.go`
6. `scheduler/queue/*`
7. `scheduler/executor/starter.go`
8. `scheduler/executor/executor.go`
9. `internal/client/store/msql/store_batch_task.go`
10. `internal/service/modelconcurrency/*`

如果只想理解业务主链路，暂时跳过测试、生成的 protobuf 和 Legacy 模块。
