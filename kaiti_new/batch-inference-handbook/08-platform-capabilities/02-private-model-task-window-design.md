# 私有模型任务窗口资源调度

## 1. 状态

`Designed`：仓库有完整设计文档，但当前代码快照没有实现或接入该调度器。不能在简历中描述为已上线能力。

完整原设计见仓库 `docs/PRIVATE_MODEL_PHASE2_TASK_WINDOW_SCHEDULING.md`。本章只保留理解架构所需的摘要。

## 2. 背景

私有部署场景可能有一个固定卡数资源池，由多个行业、多个模型共享。目标不是在同一时刻混跑全部模型，而是根据活跃Batch任务把资源池独占分配给某个行业下的某个模型，并调用底层扩缩接口完成实例启停。

它位于现有 Shard claim 之前：

```text
任务窗口调度器决定 resource pool lease归属
  → 现有Scheduler只允许lease模型claim Shard
  → Executor和结果链路保持不变
```

## 3. 复用基础

现有架构已经：

- 以 model_service_name 命名 pending/process/failed队列；
- Scheduler遍历模型并领取Shard；
- 有Redis全局周期任务模式；
- public/private模型都能映射到运行时服务；
- 能查询Ready副本、卡型和Scaler指标。

因此最小改动是在 `FindIdleShardTask` 前增加 lease过滤，而不是重写执行链路。

## 4. 核心策略

- 资源池同一时刻只属于一个行业/模型；
- 行业有显式优先级，行业内模型有显式顺序；
- 当前模型无pending/process/retry且持续空闲10分钟后切下一个模型；
- 行业整体空闲10分钟后切下一优先级行业；
- 第一版非抢占，避免中断在途推理和复杂补偿；
- 新任务到来刷新活跃时间，但不直接抢占当前活跃lease。

Go map遍历不能表示优先级，顺序必须由KConf数组/priority显式定义。

## 5. Lease 状态机

```text
IDLE → STARTING → ACTIVE → DRAINING → STOPPING → IDLE
                      └──失败──→ ERROR/RETRY
```

Redis保存当前lease和TTL，DB/审计存长期变更历史。调度器必须用 fencing token 防止旧owner在lease过期后继续发扩缩命令。

## 6. 活跃判断

不应只看 pending queue：

```text
active = pending>0 OR process>0 OR retryEligibleFailed>0
         OR DB存在pending/running Task
```

Redis活跃快照用于降扫描成本，不是唯一事实源；周期对账从队列和DB修正。

## 7. 与AutoTuner关系

- 任务窗口调度：决定“哪个模型获得GPU实例”；
- AutoTuner：决定“获得实例后Batch请求并发是多少”。

扩容到Ready后才能开放Shard claim；停止前先drain，不再claim新Shard，等待process归零或达到deadline。模型切换后AutoTuner应重置/冷却，避免沿用上一个资源形态的窗口。

## 8. 关键失败处理

- 扩容API成功但响应丢失：查询实际Runtime确认；
- lease owner退出：TTL过期，新owner凭fencing接管；
- STARTING长时间无Ready：回滚资源归属并告警；
- DRAINING超时：按非抢占原则等待/把剩余Shard恢复，不强杀未知请求；
- Redis与底层Runtime不一致：Reconciler以带revision的期望状态收敛。

## 9. 面试边界

可以说：

> 在私有模型接入后，我们进一步设计了基于任务窗口的固定资源池lease调度，复用现有模型队列，在claim前做独占归属过滤，并规划了非抢占切换和扩缩容状态机。

不可说“已经上线”“已产生收益”，除非另有真实上线证据。

