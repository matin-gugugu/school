# 遗留、未装配与重复实现

## 1. 判断方法

不能因为仓库里有代码就认为生产运行。判断顺序：

1. 镜像 entrypoint 启动哪个二进制；
2. main 是否初始化关键依赖；
3. Service.Start 是否构造并启动组件；
4. 是否有调用入口/注册；
5. 测试和文档是否只是设计。

## 2. 独立 scheduler 命令

`cmd/scheduler` 也调用同一个 `service.New(cfg).Start()`，并非纯 Scheduler；但它没有像 apiserver main 那样显式 `redis.Init()`，也没有路由/store side-effect import。

当前 Docker entrypoint 只运行 apiserver。因此独立 scheduler 应标为 `Legacy/Unwired`，不能据此画成线上独立 Scheduler 微服务。

## 3. pkg/taskprocessor

`TaskProcessorV2` 有另一套：

- JSONL下载/校验；
- 动态分片；
- OSS上传；
- Kafka Shard message思路。

但当前 Create API 调用的是 `manager.TaskCreator`，Service也没有构造 TaskProcessorV2。它的下载器还是固定5分钟Resty timeout，缺少当前 manager链路的网络分类与重试改造。

应视为历史/原型实现，避免修Bug时改错路径。

## 4. pkg/statemanager

大部分代码被整段注释，描述通过Kafka状态消息更新DB的异步架构。当前状态由 TaskCreator/Executor直接调用Store更新，不经过该组件。

这说明项目可能从“多组件事件驱动”演进到“单进程直接编排”，README/图示若仍保留前者会造成认知偏差。

## 5. TaskReconciler

`pkg/controller/taskreconciler` 有30秒循环骨架，但 reconcile内容全是TODO，也没有在 `Service.Start` 接入。

手册中提到的 init卡死、Merge卡死、队列/Metadata对账，都属于它应该承担但当前未实现的能力。

## 6. DB TaskShard方法

Executor仍保留基于GORM更新 `TaskShard` 的旧方法，但当前主流程的 Shard状态事实在 OSS Metadata。排查时应先看调用关系，不要默认DB有完整Shard行。

## 7. messages中的状态事件

`messages` 定义了 Task/Shard/Progress更新消息，但当前核心路径主要只使用TaskMessage等数据结构；状态更新消息与Statemanager设计没有装配成完整事件链。

## 8. ad-hoc工具和运维记录

`cmd/kafka-tap` 是排查工具，不是服务主链路。手工合并记录也不是自动恢复机制，且运维文档不应保存可访问的预签名URL或凭证。

## 9. 清理建议

- 在目录README标 `active/legacy/designed`；
- 删除或归档不再维护的重复代码；
- 将架构决策写ADR，解释为何当前采用单体编排；
- CI做dead-code/call graph检查；
- 测试和示例彻底移除真实凭证；
- 运行文档以镜像entrypoint和启动调用图为准。

## 10. 面试表达

> 我梳理仓库时不是按目录名画微服务，而是从镜像入口反向追调用。线上镜像只起apiserver，但它内部同时起API、TaskCreator、Scheduler、Executor和AutoTuner，所以实际是多副本单体编排。独立scheduler、TaskProcessorV2、Statemanager和TaskReconciler属于未装配或历史实现，这个区分对排障和架构复盘很重要。
