**Phase 0：通信 pattern 识别可迁移到调度器**

- **阶段 1：同节点多卡（提取拓扑无关的 pattern 本体：是什么，无拓扑干扰，定性）**
- **阶段 2：两节点两卡（校准拓扑相关代价：值多少，引入多卡通信瓶颈，定量）**

得出最终要传给调度器的 **PatternProfile + DemandVector** 格式。

> 量化不同模型、不同规模prompt/max_token 与带宽/RTT/总通信延迟之间的关系、为 K8s+LWS 的拓扑感知调度器比较placement提供评分。

#### 结果

1. **Topology-agnostic Pattern（同节点多卡得到）**
   - 例如：每个阶段的 `comm_bytes_per_token`、`comm_calls_per_token`
2. **Topology-aware Cost Model（两节点两卡得到）**
   - 例如：`bw_eff(path)`、`rtt_eff(path)`，以及“decode 小包高频 → RTT 放大”的参数
3. **给调度器的统一输入**
   - `DemandVector = Pattern × CostModel`

#### 输入

 3×3 ：

- `prompt_len ∈ {128, 512, 2048}`
- `max_token ∈ {32, 128, 512}`

再拆成两组归因用对照：用于第二阶段激励真实集群网络node_pair之间的大包带宽和小包RTT

- **prefill-heavy**：prompt_len 大（2048），max_token 小（32）
- **decode-heavy**：prompt_len 小（128），max_token 大（512）

------

#### Phase 0-1：同节点多卡，提取 pattern 本体

在**干净的同节点环境**下，抽取 TP/PP/PD 在 prefill/decode 的**通信原语结构、频次、消息规模分布**，形成拓扑无关的 Profile，同机器多卡避免引入网络拓扑的影响，只考虑不同输入规模下模型本身需要多少通信。

------

##### 例如同节点多卡TP：

按阶段（prefill/decode）分别统计：

**1) 原语直方图**

- AllGather：`count`, `bytes_total`, `msg_p50`, `msg_p95`
- AllReduce：`count`, `bytes_total`, `msg_p50`, `msg_p95`

**2) 归一化指标**：每输入token在prefill阶段产生多少字节通信（带宽代价相关），每输出token在decoding阶段产生多少次的分布式通信调用（RTT代价相关）

- `prefill_comm_bytes_per_prompt_token`
- `prefill_comm_calls_per_prompt_token`
- `decode_comm_bytes_per_output_token`
- `decode_comm_calls_per_output_token`

> 调度器要处理任意 prompt/max_token，给到调度器每 token 的通信需求，让调度器算任意输入输出规模。

**3) baseline 通信➕计算延迟**

- prefill_latency_ms
- decode_latency_per_token_ms

> 不需要把延迟解释为网络造成的，只作为基线 compute+NVLink 通信。

##### 预期 pattern

- TP-prefill：AllReduce 贡献明显（大包多） → **带宽主导需求**
- TP-decode：AllGather 小包高频（尤其 logits gather 类） → **RTT 敏感需求**

#### Phase 0-2：两节点两卡，校准真实网络拓扑代价

在**跨节点 **环境下复跑关键点，拟合链路的 **bw_eff / rtt_eff**，把“同样的 pattern”映射到“真实集群代价”，从而让调度器能预测 placement 的延迟。

- nodeA 1 GPU，nodeB 1 GPU

##### 例如两节点两卡

- prefill-heavy：(prompt=2048, max_token=32)，这个任务分布式切片的最大输入输出规模设置
- decode-heavy：(prompt=128, max_token=512)

#### 拟合参数

**1) 带宽等效值（prefill 大包）**

- `bw_eff_tp_prefill = comm_bytes_prefill / comm_time_prefill`
  （comm_time_prefill 用 prefill_latency 去掉 compute_baseline 也行；如果暂时做不到，就先用整体近似）

**2) RTT 等效值（decode 小包高频）**

- `rtt_eff_tp_decode ≈ (decode_latency - compute_baseline) / calls_decode`
  其中 calls_decode 来自 decode 的 AllGather 次数（Phase0-1 已给你 calls_per_token）

#### Phase 0-2 Topology-aware CostModel（只描述“链路代价”）

输出：

- 对路径（nodeA↔nodeB）：
  - `bw_eff_large_msg`（大包带宽）
  - `rtt_eff_small_msg`（小包 RTT）
  - 可按通信类型区分（collective/p2p/tcp）

------

##### 最终：传给调度器的 pattern 格式（你该定稿的版本）

##### 1) PatternProfile.jsonl（同节点多卡产出：需求）

```bash
{
  "meta": {
    "model": "llama-7b",
    "parallel_form": "TP",              // "TP" | "PP" | "PD"
    "parallel_size": 2,                 // TP=tp_size, PP=pp_size, PD可填1
    "env_tag": "topo_agnostic_v1"        // 标记：这是同节点多卡抽出来的“拓扑无关需求”
  },

  "workload_key": {
    "prompt_len": 2048,                 // 输入 prompt token 数
    "max_token": 128                    // 输出 token 上限
  },

  "prefill": {
    "op_histogram": [
      { "op": "AllReduce", "count": 260, "bytes_total": 6500000000, "msg_p50": 24000000, "msg_p95": 25000000 },
      { "op": "AllGather", "count": 600, "bytes_total": 1900000000, "msg_p50": 3200000,  "msg_p95": 5100000  }
    ],

    "bytes_per_prompt_token": 3200000,  // prefill 总通信量 / prompt_len
    "calls_per_prompt_token": 0.42,     // prefill 通信总次数 / prompt_len

    "small_msg_ratio": 0.05,            // 小包占比（例如 <8KB）
    "dominant_factor": "bandwidth"      // "bandwidth" | "rtt" | "mixed"
  },

  "decode": {
    "op_histogram": [
      { "op": "AllGather", "count": 128, "bytes_total": 320000000, "msg_p50": 4096, "msg_p95": 4096 }
    ],

    "bytes_per_output_token": 800000,   // decode 总通信量 / max_token
    "calls_per_output_token": 1.00,     // decode 通信总次数 / max_token

    "small_msg_ratio": 0.95,
    "dominant_factor": "rtt"
  },

  "constraints_hint": {
    "order_dependency": "low",          // PP 通常为 "high"，TP 通常 "low"
    "role_demand": null                 // PD 才需要：{"prefill":"compute-heavy","decode":"memory-heavy"}
  }
}
```



##### 2) CostModel.json（两节点两卡产出：代价）

- 按 link/path 存 bw_eff / rtt_eff

```bash
{
  "link": { "node_pair": ["A","B"], "link_type": "tcp" },
  "cost_by_comm_class": {
    "collective": { "bw_eff_large_mbps": 8000, "rtt_eff_small_ms": 0.40 },
    "p2p":        { "bw_eff_large_mbps": 9000, "rtt_eff_small_ms": 0.35 },
    "tcp_kv":     { "bw_eff_large_mbps": 7500, "rtt_eff_small_ms": 0.60 }
  }
}
```

调度器最终得到的是：

###### DemandVector（合成结果）

对任意 workload：

- `comm_time_est = bytes_per_prompt_token / bw_eff + calls_per_output_token × rtt_eff`
- PP 再加 `order_dependency` 权重（顺序依赖导致排队放大）

把问题拆成两张表：

- **PatternDemand 表**：描述“这个 workload 需要多少通信”（拓扑无关）
- **TopoCostProfile 表**：描述“这条链路传这些通信要多少钱/多久”（拓扑相关）

1. `PatternDemand`（按 workload / 模型 / 并行形态索引）
2. `TopoCostProfile`（按 node_pair / link_type 索引）

调度器运行时：

- 选定 placement → 得到 node_pair → 查 cost
- 再拿 workload 的 demand → 算 time_est → 比较不同 placement

> 把某个 rank/stage 放到某些节点上，会产生多大的通信代价？

以 TP=2 为例：

1. **读取 workload 参数**：model、prompt_len、max_token、parallel_form=TP
2. **查 demand**：从 PatternDemandDB 得到 per-token bytes/calls（prefill+decode）
3. **枚举候选 placement**：选择两个 GPU 节点作为 rank0/rank1 的落点
4. 对每个 placement：
   - 得到 node_pair=(node_rank0, node_rank1)
   - 查 cost=TopoCostDB[node_pair, "tcp"].collective
   - 计算 time_est = bytes/bw + calls×rtt（分阶段相加）
5. **选 time_est 最小的 placement** 作为调度结果

PP/PD 完全同理，只是：

- node_pair 来自 stage 或 role 的放置
- comm_class 选择不同（p2p / tcp_kv）
- PP 额外乘一个 order_dependency 权重（比如 ×1.3，表示顺序依赖更怕抖动）

面向AI推理场景的网络拓扑和共驻干扰感知的调度机制

SGLang + k3s 分布式推理任务调度编排机制是第一部分，不同的并行方式有不同的通信 pattern ， **TP** 不同 rank 做的工作基本相同只是处理的矩阵切片不同（比如hiden states按 head 数量切分），分布式计算后涉及矩阵的 collective ，**PP** stage to stage 主要是 1-1，存在order_depency， prefill vs decoding 是推理的两个阶段 ，prefill j阶段低频通信但 transformmer 层之间的通信粒度比较大规模，具体规模依赖prompt长度，decode 高频通信但小规模 ，decode执行次数依赖输出token长度，prefill 阶段重算力（大矩阵计算）和带宽（层之间大规模通信），decode阶段重 RTT 敏感（层之间通信粒度小但频率高）。我是希望能得到这些不同并行形态，不同token规模下的pattern从而给到后期的调度器做placement决策，让调度器具备AI推理pattern相关的拓扑感知。

这部分我把pattern分成了两张表来看，第一部分是在单机多卡上实验，得到的是拓扑无关的pattern，也就是模型本身相关的pattern，比如这个推理模型这些prompt_token数,这些max_token数，应该产生多少字节的通信，以及多少的通信调用次数，然后第二阶段是在sglang ➕ k3s 多机多卡上 测在当前的集群拓扑环境下，这些链路对于前面拓扑无关的到的通信要做多久，得到一些精确的带宽和RTT。

然后在后期调度器运行时：选 placement → 得 node_pair → 查 cost  → 计算 `time_est = bytes/bw + calls*rtt` 比较 placement 

第一阶段的通信识别针对AllReduce / AllGather / Send / Recv 的 count、bytes_total

也就是先在同节点多卡环境下对 TP/PP/PD 的 prefill/decode 通信结构做 profiling，采集 AllReduce/AllGather/P2P 的消息分布，并做 per-token 归一化，形成可迁移的 PatternProfile；在此基础上识别 、得到**TP-prefill**：AllReduce 大包占比高 → **带宽主导**，**TP-decode**：AllGather 小包高频（尤其 logits gather）→ **RTT 敏感**，**PP**：P2P 小包高频 + 强顺序依赖 → RTT 更容易被放大（需要 order_dependency 权重），**PD**：本体是 prefill→decode 的 KV 数据面传输，有角色上的区分，prefill端重算力，decod端重显存。是调度时候需要考虑的。

然后第二阶段，第一阶段的结果是PatternDemand：按 workload/model/parallel_form 索引的 per-token bytes/calls

TopoCostProfile：按 node_pair索引的大包带宽和小包RTT

给调度器的cost公式就是bytes_large / 带宽+ calls _small* RTT来近似通信时间

第二阶段只使用prefill-heavy，decode-heavy两种比较边界的token组合来激励：prompt_len 大、max_token 小 → 激励 **bw_eff_large**

decode-heavy：prompt_len 小、max_token 大 → 激励 **rtt_eff_small** 





更准确地说，应该理解成：

> 当你把 workload 从短请求换成中请求，再换成长请求时，某些 collective 的典型消息大小会变大，于是它们在不同 workload 下可能落入不同 bucket。

也就是：

- 在 `w_short` 里，某类事件可能主要在 `small`
- 到 `w_mid` 里，它变成 `medium`
- 到 `w_long` 里，它变成 `large`

这是**跨 workload 的 bucket 迁移**。

这才是你这个系统真正要建的东西。



那也就是说不能只靠prefill和decode阶段来单纯区分大包和小包

我可以这样，根据逻辑payload对消息桶，小桶里有来自短输入规模的prefill阶段的所谓大包，大桶里也有来自长输入规模的所谓小包，而且分别计算对应的allgather和allreduce也计算其对应的rounds实际轮次，小消息和大消息都计算，只对落在大桶里的prefill eqbyte和大包带宽一起计算为带宽开销，只对落在小桶里的decode 阶段的round和小包rtt一起计算为RTT开销。
之前两类通信原语统一计算，可能decode阶段和prefill阶段的allgather和allreduce比例不同，计算rtt时prefill阶段的calls*RTT应该✖️小权重，decode阶段的calls *RTT应该✖️大权重，



所以同样 10MB 数据：

- 如果是 160 个 64KB 小消息
- 和 10 个 1MB 中消息
- 和 1 个 10MB 大消息

真实时延不会一样。

这就是分桶存在的根本理由。



小桶里的prefill和decode对应small级别包的链路带宽和RTT

中桶里的prefill和decode对应medium级别包的链路带宽和RTT

大桶里的prefill和decode对应large级别包的链路带宽和RTT

随着输入输出规模workload组合的变化，各个桶里对应不同阶段的bytes数和rounds数会变化，那这个计算结果就不是在固定链路带宽和RTT下随着输入规模线性增长的总代价了，而是规模增大跨桶之后相当于换了一组带宽和rtt，所以非线性，对吗



****同一个 workload 下，不同 bucket 的 demand 会分别走不同的 cost 通道；**当 workload 变化时，落在各个 bucket 里的 bytes / rounds 分布变了，于是总成本变成了“多组 cost 参数加权后的结果”，这个加权结果会随着 workload 发生 regime shift，因此整体不再是单一线性函数。**



同一条链路对不同大小消息表现出不同的 `BW_eff` 和 `RTT_eff`。workload 增大后，通信更多落入另一个 message-size regime，于是总成本更多由另一组 effective cost 参数主导。

你的建模把总开销从“固定一组 BW/RTT 下的单一线性”变成了“不同 bucket 成本加权后的分段模型”；当 workload 增长引起 bucket 迁移时，总时间通常表现为分段线性，而不再是单一线性。
我将通信 demand 按 phase 和消息尺度分桶，对每个桶分别用该尺度对应的有效带宽和 RTT 估计 bytes 开销与 rounds 开销，再将各桶代价求和。这样，总通信时间不再是在固定带宽/RTT 参数下对 `prompt_length` 和 `max_token` 的单一线性函数，而是在 workload 触发消息桶迁移时表现为分段线性。