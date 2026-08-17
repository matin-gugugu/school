# 面试问题库

## 一、整体架构

### 1. 系统的核心链路是什么？

API落MySQL → HTTP流式校验/计数 → 动态分片写S3 → Redis模型队列 → Lua claim → Shard/Request两级并发 → Gateway → Redis实时进度和S3 Shard结果 → Multipart最终合并 → MySQL completed/Kafka交付。

### 2. 是微服务还是单体？

当前镜像只起apiserver，但进程内同时启动API、TaskCreator、Scheduler、Executor、AutoTuner和监控；部署是多副本单体编排。仓库独立scheduler等是未装配/历史代码。

### 3. MySQL、Redis、S3分别是什么角色？

MySQL是Task持久控制状态；Redis是短期调度、锁、缓存和实时视图；S3是大数据和Shard事实。不能只用一个系统判断全链路状态。

### 4. 为什么不用Kafka直接做全部调度？

Redis List+Lua容易实现模型独立队列和原子pending→process，代价是自建ACK、heartbeat、retry/DLQ。Kafka/Streams可降低这部分复杂度，是演进方向。

## 二、JSONL与分片

### 5. 20GB为什么不会OOM？

整文件不入内存：HTTP Scanner逐行、只缓冲当前Shard；最终Merge只保留64MiB Part。执行阶段仍整Shard驻内存，因此准确说是把边界降到Shard/Part，不是全链路常数内存。

### 6. 为什么下载两遍？

第一遍精确校验和计数，第二遍按总行数动态分片。代价是带宽翻倍和源内容变化风险，可改成首次落S3或单遍固定上限+manifest。

### 7. 如何区分坏JSON与网络截断？

组合scanner.Err、reader最后错误、Content-Length/实际字节、EOF和当前行。确定性JSON立即失败，网络中断才重试createShards。

### 8. 分片大小怎么计算？

小任务用minShardSize，大任务用ceil(N/maxShardNumber)；但maxLinePerShard>0会覆盖公式。更好是同时按行、bytes和token估算。

### 9. 如何保证结果顺序？

Request用input index回填results；Shard按数组写；最终按ShardIndex读。Kafka消息不保证顺序，只靠ID关联。

## 三、调度与执行

### 10. 多实例如何不领同一Shard？

Lua原子LPOP pending、RPUSH process并写heartbeat。单次claim不重复；执行故障恢复仍可能重做，整体at-least-once。

### 11. 为什么两级并发？

Shard并发限制常驻内存和大任务公平性；Request WorkPool限制Gateway压力/吞吐。只调Request并发不能控制同时加载多少Shard。

### 12. 哪些状态码重试？

429、529、500到505。确定性4xx不重试；未知网络错误默认可重试。MaxRetry实际是总attempt数。

### 13. 退避有什么问题？

指数退避有cap，但无jitter且time.Sleep不响应context，可能惊群和取消延迟；应full jitter+select timer。

### 14. 升级时Shard怎么恢复？

process元素保留，执行实例续Redis heartbeat。heartbeat过期且超过保护期后，全局扫描器重执行孤儿Shard。

### 15. 能保证exactly-once吗？

不能。进度和OSS副作用可幂等，但Gateway调用可能在响应丢失后重复。需要Gateway requestID幂等才能做到exactly-once effect。

### 16. 模型无Ready副本怎么办？

5秒起指数等待、最多60秒间隔；public只认offline，private允许其他池。Shard首次用Background可能无限等，是待改进点。

## 四、状态和结果

### 17. 实时进度为什么用Set？

Shard可能重做，INCR会重复；Set按稳定requestID去重，failed Set还能把失败后成功修正。snapshot让查询O(1)。

### 18. Task什么时候算成功？

所有completed Shard的TotalLines和等于Task总行数后Merge；Merge成功、output_file和计数写MySQL并触发RUN_COMPLETE后才真正completed。

### 19. 单条请求失败会让Task failed吗？

不会。Response带error，Shard仍completed，Task可completed但failed_count>0。基础设施导致Shard failed，所有Shard终结后Task才failed。

### 20. Multipart如何保证稳定？

64MiB buffer，Part独立重试；小文件直接Put；Complete error后用唯一metadata确认远端是否已成功；真失败Abort。

### 21. 当前Merge的主要风险？

每Shard完成全扫Metadata是O(S²)；outputLock只进程内且全Task串行；Merge失败不转终态/无自动重试。

### 22. 文件和消息模式差异？

文件最终有序JSONL；消息每Response异步发中转Topic再路由，可能丢/重且无序。消息模式最终文件当前只合并一个Shard，是契约风险。

## 五、AutoTuner

### 23. 自动调谐完整闭环？

ISVC Ready/卡型算上界；Gateway成功率+Scaler队列比做反馈；策略算target；写KConf；Watcher+定时器调整WorkPool；新指标进入下一轮。

### 24. 上界公式？

ceil(ΣReadyReplicas×baseline×cardRatio×safety / BatchInstances)，再clamp到1和goroutineMax之间。

### 25. 信号阈值？

成功率<.990 bad、>.995 good；queue ratio>1 bad、<.4 good；中间ok，等于边界也是ok。

### 26. 决策和步长？

任一bad回退10%上界；两个good快探5%；一个good一个ok慢探2%；其他hold；缺信号排除KSN。

### 27. 多KSN如何聚合？

缺指标KSN及容量先排除；有效KSN按rollback>hold>slow>fast。上界用有效容量重算。

### 28. 为什么只调有活跃任务的模型？

空载时queue=0看似good但没有真实成功率/吞吐，探测无意义且会改动无业务模型。DB查询失败时fail-open继续。

### 29. Gateway成功率如何防在线流量污染？

只取router request_cost中offline/Sheddable流量，2xx成功，429/5xx失败，最小100样本。

### 30. 为什么失败率下降且KV利用上升？

低压时上探提高利用率，高峰时信号恶化快速回退减少错误；不是固定增/减并发。

## 六、可靠性与演进

### 31. 最严重的卡任务窗口？

DB创建后本地goroutine丢失会卡init；Merge失败会卡running。需要create outbox和Task Reconciler。

### 32. 状态机有什么问题？

取消绕过stopping，FAIL/RUN_COMPLETE无条件，事务读不在tx且没可靠检查RowsAffected。应统一CAS/version和终态优先级。

### 33. 如何设计Task Reconciler？

扫描长init、无队列pending/running、heartbeat过期process、全Shard完成未终态、最终对象存在但DB未完成；按确定性规则补触发/重建/失败，并带lease。

### 34. 如何做消息可靠交付？

以OSS Shard结果为事实，写durable manifest/outbox和发送游标；Dispatcher重试/DLQ，对账器按taskID+requestID补发，消费者幂等。

### 35. 如何优化O(S²)进度？

Shard完成原子累加Reducer，只有最后一个触发一次全量Metadata校验和Merge；Reducer状态带幂等Shard ID。

### 36. 如何进一步降执行内存？

有界producer-consumer：Scanner读取请求提交Pool，完成结果按序号写分段文件/外排缓冲；限制reorder window，不保留整Shard requests/results字符串。

### 37. 安全风险？

禁止打印整个Config和保存真实token/预签名URL；Secret走密钥系统，日志白名单脱敏，CI secret scan并轮换历史暴露值。

### 38. 你会先做哪三个改进？

create outbox、merging状态+分布式锁/重试、Task Reconciler。先消灭永久卡死，再优化内存和消息exactly-once effect。

