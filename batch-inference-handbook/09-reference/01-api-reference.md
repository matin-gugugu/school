# API 速查

## 1. 创建 Batch

```http
POST /v1/batches
Content-Type: application/json
X-Ks-Wq-Api-Key-Id: <id>
X-Ks-Wq-Project-Id: <project>
X-Ks-Wq-Workload-Name: <name>
X-Ks-Model-Name: <display-name>
```

```json
{
  "completion_window": 86400,
  "input_file": {
    "type": "url",
    "info": {"url": "https://example/dataset.jsonl"}
  },
  "project_id": "optional-body-fallback",
  "customer_id": "optional",
  "endpoint": "/v1/chat/completions",
  "model": "model-instance-id",
  "model_scope": "public",
  "provide_method": "file",
  "result_topic": "",
  "tag": "",
  "metadata": {"description": "..."}
}
```

关键校验：

- model必填，按scope查模型实例；
- scope为空/public/private；
- private模型必须有model_project_id；
- model_service_name优先用模型实例返回值；
- customer为空时回退API Key ID；
- 创建成功返回DB Task，但异步分片尚未完成。

## 2. 获取/批量获取

```http
GET /v1/batches/{batch_id}
GET /v1/batches?batch_ids=bt-a,bt-b
```

批量最多20个ID。非终态Task会用Redis实时snapshot覆盖 request_counts.completed/failed；终态只返回MySQL持久计数。

核心响应字段：

```text
id / status / input_file / output_file
project_id / endpoint / model
completion_window / created_at / running_at / completed_at...
request_counts.total/completed/failed
errors / metadata
```

## 3. 延长超时

```http
POST /v1/batches/{batch_id}/timeout
```

```json
{"completion_window": 172800, "reason": "approved extension"}
```

限制：

- Task不能是终态；
- 新window必须>0且大于当前值；
- DB使用状态/时间条件更新，防止并发终态后仍延长；
- window单位秒，从created_at计算，不是从修改时重新计时。

## 4. 取消

```http
POST /v1/batches/{batch_id}/cancel
```

当前实现直接写 stopped，并同时写 stopping_at/stopped_at。响应成功不代表所有在途Gateway请求已立即终止，Executor依靠状态缓存/request边界逐步发现。

## 5. 删除

```http
DELETE /v1/batches/{batch_id}
```

Store使用GORM Delete；是否软删取决于模型字段。API代码未限制只能删除终态，也未在此处删除OSS对象和队列元素。调用方应确认业务契约。

## 6. 模型配置

```http
POST /v1/models/config
```

```json
{
  "model_name": "runtime-model-service",
  "max_execute_goroutine": 120,
  "max_execute_shard": 3
}
```

至少一个可更新字段，值不能为负。接口写KConf，不保证同步立即改变当前进程WorkPool。

```http
GET /v1/models/{model_name}/config
GET /v1/models/config
```

读取进程内最新KConf snapshot。

## 7. 错误响应

服务使用统一 Result envelope，业务code大体按资源/操作/HTTP语义编码。客户端应同时检查HTTP Status和响应业务code，不要只看200。

## 8. 鉴权和敏感字段

API Key/项目/用户相关header会继续传向Gateway。日志、错误响应和手册不得打印真实Key、Token、预签名URL；样例一律使用占位符。

## 9. 源码定位

- `internal/service/apiserver/api_batch/api.go`
- `internal/service/apiserver/api_batch/api_batch.go`
- `internal/service/apiserver/model_config_service.go`
- `internal/models/db/batch_task.go`

