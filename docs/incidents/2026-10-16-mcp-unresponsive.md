# 生产实例 MCP 路径无响应 — 2026-10-16 13:30 (CST)

## 现象

| 路径 | 结果 |
|---|---|
| `GET /`（Web 控制台） | **200，1.57s** — 正常 |
| `POST /mcp`（JSON-RPC） | **无响应，15s 超时，http=000** |

`docker ps` 显示容器 `Up 15 hours (healthy)` —— **健康检查误判**，因为它探的是 `/`（`curl -fsS http://127.0.0.1:8900/`），而故障只在 `/mcp` 路径上。

## 证据

```
# 容器状态
chronomem   Up 15 hours (healthy)   0.0.0.0:8900-8901->8900-8901/tcp
  StartedAt: 2026-10-15T13:52:05Z    RestartCount: 0

# 进程内存
VmRSS:  969 MB
VmPeak: 3.80 GB
VmSize: 3.01 GB

# 容器内存
1.002 GiB   （堆上限 1024 MB — 已顶满）

# 线程与 fd —— 均正常，排除连接泄漏
Threads: 11
fd:      12
```

## 日志中的故障签名

```
used summary: usedUnits 199632 (817692672 B), usedObjSize 817525448 B
objectCapacity:   0.7614 (totalObjSize 817525448 / allHeapSize 1073741824)
unitCapacity:     0.7615
usedObjectCapacity: 0.7614
[jsonrpc] handleMessage system error:            ← 空 message
```

`handleMessage system error:`（**空 message**）是此前三次写路径 OOM 事故的同一签名 —— 空 message 吞掉了异常身份。

## 内存增长是渐进的，不是突发的

近 3 小时的 GC 报告：

日志时间戳为 **UTC**（容器内 `date` 显示 05:10 UTC，宿主为 13:10 CST，同一时刻）。

| 时间 (UTC) | usedObjSize | 增量 | 距上次 |
|---|---|---|---|
| 05:01:45 | 813 046 704 B | — | — |
| 05:03:35 | 814 401 816 B | +1.3 MB | **约 2 分钟** |
| 05:05:30 | 816 129 120 B | +1.7 MB | **约 2 分钟** |
| 05:07:26 | 817 525 448 B | +1.4 MB | **约 2 分钟** |

**每约 2 分钟涨 1–2 MB，且从未回落**（约 **1 MB/min**，即每小时约 60 MB）。
按此速率，从 0 涨到 1 GB 堆上限约需 **17 小时**，与容器已运行 15 小时、进程 RSS 969 MB 相符。

这是**持续累积不释放**，而非瞬时分配峰值。

> 注意与既往事故的区别：那三次是「存活量低、**瞬时分配峰值**顶爆」（30–60 MB live vs 217–240 MB 峰值）。
> 本次是**存活量本身**缓慢爬到 817 MB 且不回收 —— 机制不同，修法可能也不同。

## 是「卡死」还是「极慢」？——进程仍在干活，不是死锁

| 观察 | 结果 | 含义 |
|---|---|---|
| 最轻请求 `tools/list`，超时 120s | `http=000`，无响应 | MCP 路径确实不可用 |
| 同容器 `GET /` | 200，1.57s | 不是网络 / 容器整体问题 |
| CPU 累计（`utime+stime`）5 秒两次采样 | 994326 → 994427（**+101 jiffies ≈ 1 核**） | **进程在消耗 CPU，不是空转等待** |
| 11 个线程的状态 | **全部 `S`（sleeping）** | 无自旋、无典型死锁 |
| 内存 | 969 MB → 921 MB（缓慢下降） | GC 仍在回收 |

所以不是死锁，而是 **MCP 处理路径被拖到无法在合理时间内完成响应**：CPU 在烧、
线程在睡（等 I/O 或定时器），而请求始终不返回。

一个与现象吻合的解释（**待验证，非结论**）：JSON-RPC 处理是串行的，一旦某个请求
（或它触发的物化 / 总结任务）长时间占用处理链，后续请求就全部排队 —— 而 `/` 是独立的
HTTP 静态路径，因此不受影响。这与「健康检查探 `/` 所以误报 healthy」是同一个原因。

## 根因定位：物化遍历卡在 `diag_probe2` 上

`materializeAll` 按固定顺序遍历全部 series。近 30 分钟的日志显示，**每一次遍历都恰好停在同一个
位置**，其后不再有任何输出：

```
materializeAll series=worklog            levels=[day, week]
materializeAll series=worklog.summary    levels=[day, week]
materializeAll series=conn_test          levels=[day, week]
materializeAll series=conn_test.summary  levels=[day, week]
materializeAll series=diag_probe2        levels=[day, week]     ← 每次都停在这里
（此后无输出）
```

| 观察 | 值 |
|---|---|
| 最后一次日志时间 | `05:12:45.500Z` |
| 检查时刻 | `05:14:32Z` |
| 静默时长 | **107 秒无任何日志** |
| 同期 CPU | 累计时间持续以约 1 核速率增长 |
| 同期线程状态 | 全部 `S`（等 I/O / 定时器，非自旋） |
| `materializeAll` 近 10 分钟调用次数 | 188 次（约每 3 秒一轮） |
| `diag_probe2` 在日志中出现 | 1831 次 |

**症状与机制一致**：物化遍历在 `diag_probe2` 上阻塞 → 该后台任务不结束 → JSON-RPC 串行处理链
被后续到达的请求持续排队 → `/mcp` 全部超时；而 `/` 是独立 HTTP 路径，仍即时返回 200（这也回答了
健康检查为什么一直报 healthy）。

### `diag_probe2` 与同批 `selftest/*`、`conn_test` 是测试遗留类型

遍历顺序里还有一批明显属于调试遗留、**不属于本工作区正常业务**的类型：

```
selftest/hang-probe[.summary]   selftest/se-probe[.summary]
selftest/se-probe2[.summary]    selftest/connfix[.summary]
conn_test[.summary]             diag_probe2[.summary]
```

名字本身就说明了用途（`hang-probe` = 挂起探针，`se-probe` = 系统错误探针，`conn_test` = 连接测试）。
这些是此前排查本类问题时的诊断类型，而**本次故障恰好卡在其中之一的物化上**。

> 这形成一个闭环：为了排查「MCP 挂起」而建的探针类型，自身成了下一次挂起的触发点。

## 未做的事（需授权）

- **未重启容器**。重启是生产操作，且会丢失重启前的未落盘写入；另有已知的关闭钩子落盘风险
  （见工作区 AGENTS.md「部署会不会丢数据，取决于关闭钩子」——chronomem 的钩子只停一个后台执行器，
  历史上未踩到该坑，但重启前仍应确认）。
- **未改任何配置**。

## 影响

- `bench/semantic_survival.py`（语义存活测量）依赖生产语料的 `mem/summaries` 读取，**因此阻塞**。
- 论文评审意见 4 的语义指标部分无法完成，直到实例恢复。
- **`dsh-mem-bridge` 的自动会话账写入也在失败**（它走同一个 `/mcp`）——即忆时塔自身的记忆记录已中断约数小时。

## 建议的下一步（待定）

1. **先取一份堆转储**（若镜像内有工具），再重启——否则同样的泄漏会再来一次。
2. 重启后立刻验证：`POST /mcp` 的 `mem/list_types` 是否恢复；确认最近的 worklog / dsh/activity 条目没丢。
3. 把健康检查从 `/` 改为探 `/mcp`（当前配置会持续误报 healthy）。
4. 定位泄漏：本轮唯一新增的压力来源是**大量 `mem/summaries limit=500` 读取**（本会话为统计重复总结而调用过多次），
   以及 `bench` 实例的持续写入 —— 需查 `/mcp` 路径上是否有按请求累积的驻留（如分页遍历整表、摘要列表整表驻留）。
