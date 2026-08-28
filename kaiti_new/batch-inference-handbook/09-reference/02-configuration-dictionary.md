# 配置字典

所有数值必须以实际环境KConf/启动配置为准；表中只说明代码语义。任何密钥字段不得写进手册、日志或工单。

## 1. 任务接入与分片

| 字段 | 单位 | 语义 |
| --- | --- | --- |
| min_shard_size | 行 | 动态分片最小行数 |
| max_shard_number | 个 | 动态公式期望最大Shard数 |
| max_line_per_shard | 行 | >0时直接覆盖动态公式结果 |
| max_jsonl_line_bytes | byte | 输入Scanner单行上限 |
| dataset_connect_timeout_seconds | s | HTTP建连超时 |
| dataset_response_header_timeout_seconds | s | 响应头超时 |
| dataset_read_idle_timeout_seconds | s | 连续无读取进展超时 |
| create_shards_max_attempts | 次 | 网络中断型分片重建总attempt |
| create_shards_retry_delay_seconds | s | 分片重建间隔 |

注意：`max_line_per_shard>0` 会使 `min_shard_size/max_shard_number` 公式失效。

## 2. 调度和恢复

| 字段 | 单位 | 语义 |
| --- | --- | --- |
| scheduler_interval | s | process调度周期 |
| pending_scheduler_interval | s | 当前启动路径对应任务被注释 |
| failed_scheduler_interval | s | failed queue调度周期 |
| pending_task_retry_interval | s | pending重试窗口参数 |
| failed_task_retry_interval | s | failed首次可重试等待 |
| failed_max_retry_interval | s | failed最大时间窗口 |
| open_silky_upgrade | bool | 开启process heartbeat恢复 |
| mark_live_minutes | min | heartbeat续期后的TTL |
| mark_update_minutes | min | heartbeat更新周期 |
| upgrade_check_interval | s | 全局扫描抢锁检查周期 |
| upgrade_execute_interval | s* | 传给锁TTL/执行间隔；注释单位有歧义，按代码time.Second使用 |

## 3. 请求执行

| 字段 | 单位 | 语义 |
| --- | --- | --- |
| worker_config.max_retry | attempt总数 | 每请求Gateway最多调用次数 |
| worker_config.base_delay | ms | 指数退避基数 |
| worker_config.max_retry_delay | ms | 退避上限 |
| http_req_time_out_minutes | min | 单次Gateway HTTP总超时 |
| work_pool_cap_check_interval | s | KConf到Runtime Pool更新周期 |
| service_instance_num | 个 | 容量上界分摊使用的Batch实例数 |
| goroutine_max | 个/实例/模型 | AutoTuner硬上限 |

`worker_config.max_concurrency`、全局 `work_pool_cap` 已标delete，主流程使用模型KConf。

## 4. 每模型KConf

```yaml
model_config:
  models:
    <model-service-name>:
      model_service_name: <name>
      max_execute_shard: 3
      max_execute_goroutine: 100
      auto_reconcile_enabled: true
      per_instance_concurrency:
        baseline_concurrency: 80
        ksn_concurrency:
          <ksn>: 80
```

| 字段 | 含义 |
| --- | --- |
| max_execute_shard | 单进程该模型同时运行Shard数 |
| max_execute_goroutine | 单进程该模型请求WorkPool cap |
| auto_reconcile_enabled | Ready容量Reconciler是否处理模型 |
| baseline_concurrency | 基准卡型单副本并发 |
| ksn_concurrency | KSN单副本并发映射 |

Runtime把goroutine/shard的<=0分别回退到10/5，不能用0暂停。

## 5. AutoTuner

| 字段 | 默认 | 含义 |
| --- | ---: | --- |
| auto_tuner_enabled | false* | 反馈探测全局开关；未配置指针时false |
| gateway_request_success_rate_enabled | false* | 独立Gateway Collector开关 |
| gateway_request_success_rate_bucket_seconds | 30 | 成功率桶 |
| gateway_request_success_rate_min_total | 100 | 最小请求样本 |
| metrics_sample_interval_seconds | 30 | Scaler采样间隔 |
| metrics_window_seconds | 600 | 滑动窗口 |
| tune_interval_seconds | 300 | 调谐周期 |
| success_rate_bad_threshold | .990 | 低于为bad |
| success_rate_good_threshold | .995 | 高于为good |
| queue_load_ratio_good_threshold | .4 | 低于为good |
| queue_load_ratio_bad_threshold | 1.0 | 高于为bad |
| probe_fast_step_ratio | .05 | 快探步长/上界 |
| probe_slow_step_ratio | .02 | 慢探步长/上界 |
| rollback_step_ratio | .10 | 回退步长/上界 |
| initial_explore_goroutine | 100 | 首轮起点 |
| upper_bound_change_reset_threshold | .2 | 代码当前未启用reset |
| card_type_ratios | 无 | 卡型能力比例，缺失会回退/排除 |

## 6. 外部依赖

| 配置组 | 内容 |
| --- | --- |
| store | MySQL DSN/连接池 |
| redis | Sentinel master/addrs |
| s3_config | region/endpoint/bucket/credentials |
| gateway_config | domestic/oversea URL/API key |
| openapi/private_openapi | 模型元数据URL/token |
| isvc_config | Runtime API host |
| scaler_config | View API URL |
| kafka_config | Gateway perflog topic/group/biz |
| sms_config | 欠费SMS、去重/聚合TTL |
| kim_notice | 项目路由与webhook |

## 7. 任务与结果Topic

- task_notice_topic：Task生命周期通知；
- task_req_result_topic：逐请求中转结果；
- KafkaConfig中的task processor/shard/status topic属于历史/其他设计，当前主编排不依赖完整事件链。

## 8. 校验缺口

`Config.Validate()` 当前直接返回nil。生产启动前应强校验：正数时间、service_instance_num、分片参数、retry关系、heartbeat TTL关系、必需URL和Secret引用，避免运行期才暴露除零/空指针/忙循环。

