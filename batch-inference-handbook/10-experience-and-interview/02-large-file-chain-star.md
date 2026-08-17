# 核心经历一：20GB JSONL 链路重构

## 1. STAR 主回答

### Situation

原有批任务处理大文件时，如果下载、分片或结果合并需要整文件/整任务结果常驻内存，会出现OOM、临时磁盘不足、上传失败全量重做等问题；网络中途断流还可能被误报成末行JSON错误，定位困难。

### Task

在不改变用户JSONL协议和最终有序结果的前提下，降低内存与磁盘峰值，提高20GB级单文件的处理稳定性，并让网络错误、格式错误可区分、可恢复。

### Action

1. 自定义HTTP streaming reader，分别控制连接、响应头和read-idle timeout，并跟踪Content-Length/实际读取字节；
2. Scanner逐行验证JSON，结合EOF、读取状态和Content-Length区分输入格式错误与网络截断；
3. 第一遍校验/计数，按 `max(minShardSize, ceil(N/maxShardNumber))` 计算Shard行数，并由maxLine配置做硬上限；
4. 第二遍逐行生成稳定request ID，只缓冲当前Shard，写确定性S3 data/meta对象；
5. 结果按request index回填，Shard内和跨Shard保持原顺序；
6. 最终合并顺序读取Shard结果，只保留64MiB buffer，满Part即UploadPart；
7. Initiate/Part/Complete做重试，Complete响应丢失时用task/count/merge_time metadata确认对象是否实际完成；失败则Abort，配合指标和日志。

### Result

`Experience Result`：稳定支持20GB单文件处理。内存不再与整任务输入/输出总量线性增长，最终合并主要受固定64MiB Part和单行buffer约束。

## 2. 为什么不是单遍

当前精确动态分片需要先知道总行数，再决定linePerShard，所以下载两遍：

```text
pass1: validate + count
pass2: assign ID + shard + upload
```

优点是Shard数/大小可预测、非法输入在入队前整体失败；代价是源站带宽和时间约2倍，第二遍内容理论上可能变化。

后续可以：

- 首次下载同时落原始S3，再从稳定对象切分；
- 单遍按固定上限切分，结束后写manifest；
- URL提供ETag/version，两个pass做一致性校验。

## 3. 内存边界准确说法

不能说“全链路O(1)”：

```text
输入接入：O(当前Shard)
Shard执行：O(Shard requests + responses + serialized result)
最终合并：O(64MiB + 当前行)
```

20GB不整体常驻，但单Shard过大、响应大、Shard并发高仍会造成内存峰值，所以MaxLinePerShard、max_execute_shard和请求并发要联合压测。

## 4. 动态分片公式

设计公式：

```text
if N <= maxShardNumber × minShardSize:
    linesPerShard = minShardSize
else:
    linesPerShard = ceil(N / maxShardNumber)
```

但代码中 `max_line_per_shard>0` 会直接覆盖公式。面试时应主动指出“当前线上通过硬行数上限控制内存，动态公式是默认策略”。

## 5. 网络错误分类

Scanner返回false可能是：

- 正常EOF；
- token过长；
- reader网络错误；
- 响应提前结束；
- 最后一行本身非法JSON。

分类时组合：scanner.Err、reader.LastError、expected/actual bytes、当前行号和截断摘要。只有网络中断型错误才自动重跑createShards；确定性JSON错误立即失败，避免无意义重试。

## 6. Multipart细节

- 小于64MiB不启动Multipart，直接Put；
- 64MiB每Part，最多10000 Part；
- 20GiB约320 Part；
- Part按顺序记录ETag，最后Complete；
- Complete报错后HEAD metadata确认“远端成功、本地未知”；
- 真失败Abort，S3 lifecycle清残留会话。

## 7. 高频追问

### 为什么分片按行数而不是字节？

JSONL天然以请求行为边界，行数更容易保证请求完整和结果计数；缺点是行大小分布不均。改进是同时限制行数和累计bytes/token估算。

### 如何保证结果顺序？

请求并发执行但写 `results[inputIndex]`；Shard结果按数组顺序保存；最终按ShardIndex顺序读取，所以文件有序。Kafka消息不保证顺序。

### Complete为什么需要metadata确认？

Complete可能已在S3提交但响应丢失。仅凭客户端error会误判；匹配本轮唯一metadata可以确认目标对象确实是本次Merge的成功结果。

### 20GB如何验证？

说明真实做过的压测维度：文件大小/行数、Shard数、峰值RSS、临时磁盘、S3吞吐、总耗时、断流/Part失败/实例重启。没有留存的数字不要临时编造。

### 当前最大的遗留问题？

执行仍整Shard驻内存，Task汇总O(S²)，Merge失败无自动补偿、跨副本无锁。优先用有界pipeline、增量Reducer和per-task Merge lease解决。

## 8. 代码级调用链

```text
CreateBatch
→ TaskCreator.CreateTask
→ validateDataset
→ downloadFromHTTPWithProgress
→ getShardSize
→ createShardsWithRetry/createShardsOnce
→ uploadShard/enqueueShards
→ Executor.processShardData/saveResults
→ updateTaskProgress
→ MergeShardOutputs
→ multipartMergeWriter
→ RUN_COMPLETE
```

