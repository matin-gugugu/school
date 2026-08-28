# 手册验证记录

## 1. 文档快照

```text
branch: master
commit: 09ca42d0e4fc3fabbbd088e61823ace0b8154710
commit time: 2026-08-04T07:10:11Z
verification date: 2026-08-17
```

## 2. 文档检查

- 模块化Markdown、快速复习和全文版均已生成；
- 相对Markdown链接检查：0个断链；
- 手册内敏感值模式扫描：未发现实际凭证或预签名URL；
- `FULL_HANDBOOK.md` 由 `build_full_handbook.sh` 机械生成；
- 未修改业务代码；
- 仓库原有的两个未跟踪docs文件保持不变。

## 3. Go测试结果

执行：

```text
go test ./...
```

全仓未通过。失败分为：

1. stale example：示例引用已不存在的OSS构造函数；
2. stale MQ test：测试使用了已变化的TaskMessage字段/类型；
3. integration environment：MySQL、KConf、modelcache测试依赖公司运行环境/配置；
4. sandbox restriction：Gateway Redis聚合测试需要本地监听端口，当前沙箱拒绝bind。

核心链路在全量输出中通过的包包括：

```text
manager
scheduler/executor
internal/service/modelconcurrency
internal/service/modelconcurrency/tests
internal/scaler
internal/isvc
internal/models/db
internal/service/apiserver/api_batch
internal/service/accountfreeze
internal/config
```

该记录不代表线上环境验证，也不应掩盖全仓测试基线本身需要修复。

## 4. 安全检查发现

仓库已有代码/运维文档中存在敏感信息治理风险，例如完整配置日志、真实凭证样例或预签名结果链接。本手册没有复制这些值。

建议按组织安全流程：

- 对仍可能有效的凭证/链接失效或轮换；
- 清理Git历史和运维文档中的敏感值；
- 日志改为字段白名单和脱敏输出；
- CI加入secret scanning；
- 测试fixture只用无效占位符。

## 5. 事实一致性抽查

已针对源码重新核对：

- 当前容器/服务启动链路；
- JSONL两遍读取、Scanner上限和分片覆盖逻辑；
- Redis三队列和Lua claim；
- 429/529/500-505请求重试；
- 实时进度Lua与终态closed；
- 64MiB Multipart和10000 Part上限；
- AutoTuner 30s/600s/300s时间尺度；
- .990/.995、.4/1.0阈值及5%/2%/10%步长；
- Ready Capacity、卡型比例、有效KSN排除与KConf写回。

线上KConf可能与仓库示例不同，运行参数必须以目标环境为准。

