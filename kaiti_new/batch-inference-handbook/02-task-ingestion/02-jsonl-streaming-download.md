# JSONL 流式下载

## 1. 要解决的问题

输入文件可能达到 20GB。简单实现通常有三类风险：

1. `io.ReadAll` 导致内存与文件大小线性增长；
2. HTTP 建连成功但 Body 中途长时间无数据，任务永久挂住；
3. TCP/代理中断后得到 EOF 或残缺行，被误判为用户 JSON 错误。

当前实现返回一个流式 `io.ReadCloser`，Scanner 一边读取一边处理，不保留完整文件。

## 2. HTTP 客户端

下载过程先尝试 HEAD，再执行 GET。

### 2.1 HEAD

HEAD 用于记录：

- HTTP Status；
- Content-Length；
- ETag；
- Last-Modified。

HEAD 失败不是致命错误，系统继续 GET，兼容不支持 HEAD 或签名 URL 对 HEAD 有限制的源站。

### 2.2 GET

GET 必须返回 HTTP 200，否则关闭 Body 并返回错误。

客户端关闭自动透明压缩：`DisableCompression=true`，同时请求 Header 设置了 `Accept-Encoding`。由于 Go Transport 在 DisableCompression 下不会自动解压，若源站真的返回 gzip Body，Scanner 可能读到压缩字节。当前生产源应返回未压缩 JSONL；这是需要在接入契约中明确的边界。

## 3. 三类超时

| 超时 | 默认值 | 解决的问题 |
| --- | --- | --- |
| Connect Timeout | 10s | TCP 建连不可达 |
| Response Header Timeout | 30s | 已连接但服务迟迟不返回 Header |
| Read Idle Timeout | 120s | Body 读取过程中长时间没有任何字节 |

此外 TLS Handshake Timeout 为 10s，连接 KeepAlive 30s。

这些超时可由配置覆盖：

```yaml
dataset_connect_timeout_seconds: 10
dataset_response_header_timeout_seconds: 30
dataset_read_idle_timeout_seconds: 120
```

## 4. datasetHTTPReadCloser

包装 Reader 维护以下状态：

```go
type datasetReadState struct {
    BytesRead     int64
    ContentLength int64
    TimedOut      bool
    LastErr       error
}
```

### 4.1 Read 流程

```text
Read(p):
  在读取前重置 idle timer
  调用底层 Body.Read
  如果 n > 0:
      原子累加 bytesRead
      再次重置 idle timer
  如果 err != nil:
      停止 timer
      如果是 idle timeout:
          包装为明确的 read idle timeout
      非 EOF 错误保存为 lastErr
  返回 n, err
```

### 4.2 Idle Timer

Timer 到期后：

```text
timedOut = true
lastErr = dataset read idle timeout
close underlying response body
```

关闭 Body 用来打断正在阻塞的 Read。

状态字段使用 Mutex 和 Atomic 保护，避免 Timer goroutine 与 Scanner goroutine产生数据竞争。

## 5. 完整性检查

Scanner 返回 EOF 不一定代表完整读取。扫描结束后执行：

```text
如果 LastErr == nil
且没有超时
且 ContentLength 未知或 BytesRead >= ContentLength
    → 完整
否则
    → incomplete body / stream interrupted
```

这种检查能识别“底层连接提前关闭但上层只看到文件结束”的情况。

## 6. 内存模型

流式下载本身的内存主要包括：

- Scanner Buffer：初始约 1MiB，最大由 `max_jsonl_line_bytes` 控制，默认 10MiB；
- 当前行字节；
- 创建分片时的当前 Shard Buffer；
- HTTP Transport 缓冲。

因此：

```text
下载内存 O(maxLineSize)
分片阶段总内存 O(currentShardBytes)
而不是 O(totalDatasetBytes)
```

“支持 20GB 文件”指总文件不驻留内存，不表示内存完全与配置无关。单行上限和单 Shard 行数仍需要合理配置。

## 7. 当前会下载两遍

TaskCreator 当前流程：

```text
第一次 GET：校验全部 JSONL + 统计行数
→ 计算动态分片大小
第二次 GET：再次读取 + 创建并上传 Shard
```

优点：

- 能精确控制 Shard 数量；
- 在写任何 Shard 前确认整个数据集 JSON 格式有效；
- 分片公式可以使用准确总行数。

代价：

- 20GB 输入可能产生约 40GB 源站读取流量；
- 总预处理耗时接近两次完整扫描；
- 如果 URL 内容在两次 GET 之间变化，验证对象和分片对象可能不同。

可以通过 ETag/Last-Modified 一致性检查缓解内容变化；当前代码只记录这些 Header，没有跨两遍强校验。

## 8. 可演进方案

### 方案 A：先落原始文件到平台 OSS

```text
源站单次流式下载 → 平台 OSS 原始对象
→ 对稳定对象扫描和分片
```

仍需要读取两次，但只向源站下载一次，并获得稳定数据版本。

### 方案 B：固定最大行数单遍分片

不提前统计行数，按 `max_line_per_shard` 单遍切分。网络和预处理更省，但无法严格控制 `max_shard_number`。

### 方案 C：预估 + 末端调整

根据 Content-Length 和采样平均行大小预估分片，复杂度更高，也可能产生不均匀 Shard。

## 9. 监控与日志

建议重点观察：

- HEAD/GET status；
- content_length 和 bytes_read；
- connect/header/read-idle timeout；
- ETag/Last-Modified；
- validation 与 create_shards 两阶段耗时；
- 中断分类和重试次数；
- 单行最大字节数；
- 单 Shard 实际字节数。

## 10. 面试表达

> 大文件链路没有设置一个覆盖整个下载过程的短总超时，而是把建连、响应头和读空闲分别控制。Body Reader 记录已读取字节与 Content-Length，并在长时间无数据时主动关闭底层连接。这样既允许 20GB 文件长时间持续传输，也能识别中途断流和静默截断。

## 11. 源码定位

- `manager/processor_http_downloader.go`
- `downloadFromHTTPWithProgress`
- `datasetHTTPReadCloser.Read`
- `datasetHTTPReadCloser.datasetReadState`
- `manager/validation.go`
- `manager/dataset_error.go`
