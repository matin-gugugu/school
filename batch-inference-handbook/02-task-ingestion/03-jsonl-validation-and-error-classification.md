# JSONL 校验与错误分类

## 1. 输入契约

数据集必须是 JSON Lines：

- 一行对应一个请求；
- 每行必须是 JSON Object；
- 不允许空行；
- 单行字节数不能超过 `max_jsonl_line_bytes`，默认 10MiB。

基础行校验：

```text
trim spaces
if empty: error
if first byte != '{' or last byte != '}': error
json.Unmarshal into map[string]interface{}
```

随后创建 Shard 时还会反序列化为 BatchRequest，并给请求生成平台 ID。

## 2. 为什么错误分类困难

假设网络在一行 JSON 中间断开：

```json
{"custom_id":"1","body":{"messages":[...
```

Scanner 可能把残缺字节作为最后一个 token 返回。JSON 校验看到的是“缺少右大括号”，但真实原因可能是传输中断而不是用户文件格式错误。

错误分类关系到是否重试：

- 确定的数据格式错误：重试不会改变结果；
- 网络中断：重新下载可能成功。

## 3. 校验阶段

第一次扫描只做完整数据集验证和计数：

```text
dataCount = 0
for Scanner.Scan():
    line = Scanner.Bytes()
    validateJSONObject(line)
    dataCount++

check Scanner.Err()
check ContentLength/BytesRead completeness
return dataCount
```

## 4. JSON 失败分类算法

某行校验失败后，系统不会立即返回 JSON 错误，而会额外调用一次 `scanner.Scan()`。

### 4.1 下一行存在

```text
当前行 JSON 非法
且下一行存在
→ 文件确实包含非法 JSON 行
→ 返回 json format error
```

因为传输已经越过当前行并读到下一行，当前行不是因 EOF 截断。

### 4.2 Scanner 报 token too long

如果额外 Scan 或正常扫描返回 `token too long`：

```text
→ JSONL 单行超过 max_jsonl_line_bytes
→ 确定的数据格式/规格错误
→ 不按传输中断重试
```

### 4.3 Scanner 返回其他错误

结合 Reader 状态分类：

| Reader 状态 | 分类 |
| --- | --- |
| `TimedOut=true` | `read_idle_timeout` |
| `LastErr=io.ErrUnexpectedEOF` | `unexpected_eof` |
| `LastErr!=nil` | `read_error` |
| `BytesRead < ContentLength` | `unexpected_eof_before_content_length` |
| 无明确状态 | fallback scanner error |

这类错误包装成 `datasetStreamInterruptedError`，允许创建 Shard 时重试。

### 4.4 到达 EOF

如果当前错误行后没有下一行，也没有 Scanner error：

- Reader 有 LastErr/TimedOut/未读满 Content-Length：传输中断；
- Reader 完整读取：最后一行本身就是非法 JSON。

## 5. 普通 Scanner 失败

没有先发生 JSON 校验错误，但扫描器最终返回错误时：

- token too long → 格式/规格错误；
- 其他错误 → 结合 Reader 状态归类为传输中断。

错误信息保留：

- 已扫描行数；
- 预计错误行号；
- 当前 ShardIndex；
- 当前 Shard 已累计行数；
- bytes_read、content_length、remaining_bytes；
- 是否 timeout；
- 原始 Scanner error。

## 6. 扫描成功后的完整性检查

即使 `Scanner.Err()==nil`，仍执行：

```text
if LastErr != nil
or TimedOut
or ContentLength >= 0 and BytesRead < ContentLength
    → datasetStreamInterruptedError
```

这是为了覆盖静默的提前 EOF。

## 7. 重试策略

创建 Shard 的重试只针对：

```text
isDatasetStreamInterruptedError(err) == true
```

默认：

```text
maxAttempts = 3
retryDelay = 5 seconds
```

明确 JSON 格式错误、上传失败或其他逻辑错误不会进入这段传输重试。

注意：每次重试会从头重新下载和重建本轮 Shard。已成功上传的同名 Shard 对象会被覆盖，但如果新一轮比上一轮产生更少 Shard，旧的多余对象可能残留；最终 TaskMetadata 只引用本轮结果。

## 8. 日志中的数据保护

非法行日志不会输出整行，而是记录：

- 原始/Trim 后字节数；
- 首尾字节；
- 前 256 字节预览；
- 后 256 字节预览。

这能辅助判断截断或编码问题，但请求体可能包含用户数据，生产日志仍应按数据安全要求脱敏和限制访问。

## 9. 典型案例

### 文件第 100 行确实非法，第 101 行存在

```text
classify = json_format_error
retry = false
Task = failed
```

### 文件最后一行在网络传输中被截断

```text
JSON parse failed
next line = false
bytes_read < content_length
classify = stream_read_interrupted
retry = true
```

### 单行超过 10MiB

```text
Scanner error contains token too long
classify = line_too_long/json_format_error
retry = false
```

### 源站长时间不发送任何 Body 字节

```text
idle timer closes response body
TimedOut = true
classify = read_idle_timeout
retry = true
```

## 10. 面试表达

> 大文件链路里一个重要问题是“网络截断会伪装成 JSON 格式错误”。我们在 JSON 失败后继续探测下一行，并结合 Scanner error、Read Idle Timeout、已读字节和 Content-Length 分类。只有传输中断才重试，确定的脏数据立即失败，避免无效重试放大源站和 OSS 压力。

## 11. 源码定位

- `manager/validation.go`
- `manager/dataset_error.go`
- `manager/task_creator.go: runCreateShardsWithRetry`
- `manager/processor_http_downloader.go: datasetHTTPReadCloser`
