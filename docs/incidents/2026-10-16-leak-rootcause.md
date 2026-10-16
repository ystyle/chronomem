# 内存泄漏根因定位（2026-10-16）

> 位置：`cjxt` 的 `SessionManager` —— **会话永不回收**，每个会话持有完整渲染树。
> 证据：生产 OOM 堆转储（160MB `cj_OOM_pid1.dat`）经官方 `cjprof heap` 分析。

## 一、结论

| 项 | 数据 |
|---|---|
| 泄漏对象 | `cjxt::Session` **1756 个**，Retained **608 MB**（占 1GB 堆 **57%**） |
| 连带对象 | `cjxt::SessionContextState` 1756、`chronomem.cli::OverviewPage` **1753**、`cjxt::VNode` 686854 |
| 持有者 | `cjxt::App` → `SessionManager` → `HashMap<String, Session>`（Retained 515 MB） |
| 平均每会话 | **338 KB**（= 一棵完整渲染树，随记忆条数增长） |
| 触发条件 | 每次 `GET /` 都 `sessions.create(...)`；健康检查每 30s 一次 → 持续累积 |

## 二、堆转储分析（cjprof heap -i cj_OOM_pid1.dat）

```
Object Type                                                       Objects        Shallow Heap   Retained Heap
================================================================  =============  =============  =============
std.collection::HashMap<std.core::String,std.core::String>               589135       51843880      641800624
cjxt::VNode                                                              686854              0      614524184
RawArray<cjxt::IComponent>                                               686239       17650944      613422184
cjxt::Session                                                              1756         323104      608233584   ← 元凶
cjxt::App                                                                     1            320      515923616
cjxt::SessionManager                                                          1             24      515922080
std.collection::HashMap<std.core::String,cjxt::Session>                       1             88      515922056
chronomem.cli::OverviewPage                                                1753         126216        2233440   ← 1753 个页面实例
cjxt::SessionContextState                                                  1756          42144         684416
```

## 三、代码根因

`cjxt/src/session.cj` 的 `SessionManager`：

```cangjie
public class SessionManager {
    let sessions = HashMap<String, Session>()      // 只增不减
    ...
    public func cleanup(): Unit {                  // ← 从未被任何代码调用
        for ((id, session) in sessions) {
            if (session.isExpired(ttlMillis)) { sessions.remove(id) }
        }
    }
}
```

`cjxt/src/app.cj`：

```cangjie
private func servePage(ctx, p, routeParams): Unit {
    let session = sessions.create(p, text(""))     // 每次 GET / 都建新会话
    ...
}
// sessions.remove(sid) 只在 WebSocket 正常断开时调用（app.cj:275）
```

**验证**：`grep -rn "\.cleanup()" cjxt/src cjxt/examples` → **零调用点**。
`SessionManager(300000)` 的 5 分钟 TTL 形同虚设。

### 为什么健康检查是主要触发源

- `curl /`（无 WS）→ `sessions.create()` 建会话 → 该连接不会走 WS 关闭路径 → **永不 remove**
- Dockerfile `HEALTHCHECK --interval=30s CMD curl -fsS http://127.0.0.1:8900/`
- 23 小时 ÷ 30s ≈ 2777 次；dump 实测 1756 个（后段 OOM 期间请求失败未创建，数量级吻合）
- 反推：1756 个 ⇒ 平均 47.5 秒/个

### 为什么之前小库实验复现不出

隔离实例只有 ~200 条记忆 → 渲染树小 → 每会话仅几 KB →
300 次 `GET /` 只涨 4KB（实测），200 条 WS 连接 GC 低点无变化。
**生产 1887 条记忆 → 每会话 338KB**，才能显性化。
→ 教训：小数据量复现大对象泄漏会漏报，必须用**生产同量级**数据。

## 四、连锁故障

泄漏到堆顶后，触发一条正反馈链：

1. 堆贴顶（`active units 262139/262144` = 99.998%）→ 每次分配都触发 GC
2. GC 每 ~2s 一次但回收不动（`released units` 瞬间被填回）
3. 处理被拖慢 → `GET /` 超时（>10s）
4. 健康检查超时（`exit=-1`）→ **未回收的连接累积**（fd 10 → 84、TCP 24 → 144）
5. 连接压力 + 内存压力互相放大
6. 最终持续抛 `Out of memory`（`OutOfMemoryError`），服务不可用

> 注：首次事故记录（13:30）称「fd=12，排除连接泄漏」——那是**恶化早期**。
> 连接泄漏在进入 OOM 阶段后才显性化，两者是同一根因的两个阶段。

## 五、修复

### 已实施

| # | 位置 | 改动 |
|---|---|---|
| 1 | **cjxt**（根治） | `App.startSessionSweeper()`：后台线程周期调 `SessionManager.cleanup()`（默认 30s）。**`serve()` 与 `router()` 都启动** —— 合并单端口模式（忆时塔 UI+MCP 同端口，UI 作为 fallback 挂在宿主 distributor 上）不走 `serve()`，只在 serve 里启动等于没修。 |
| 2 | **cjxt**（根治） | 两档 TTL：已建 WS 用 `ttlMillis`（5 分钟）；从未建 WS 的用 `detachedTtlMillis`（60s）。新增 `Session.everConnected()` / `markConnected()`。健康检查这类一次性请求因此被快速回收。 |
| 3 | **cjxt**（根治） | 修正 `cleanup()` 的**迭代期删除**：原在 `for ((id, s) in sessions)` 里 `remove(id)`，HashMap 迭代期修改行为未定义（可能跳过元素）；改为先收集 key 再逐个删。另把 `isExpired(ttl<=0)` 明确为「立即过期」，使边界可测。 |
| 4 | **chronomem** | 健康检查由 `GET /` 改为 JSON-RPC `tools/list` 探 `/mcp`：既消除泄漏触发源，也修正判据（`/` 与 `/mcp` 独立，实际出现过一条挂掉另一条正常）。 |

> 不能用 `GET /mcp` 做探活：那是 SSE 长连接端点，会挂住直到超时（实测 8s 无响应）。

### 验证（cjxt 侧，含变异验证）

`src/session_cleanup_test.cj` 7 例：回收过期 / 保留未过期 / 两档 TTL 分流 /
`markConnected` 置位 / 20 个过期会话一次全删（钉迭代期删除）/ App 手动巡检 /
巡检幂等。主包 336/336 全绿。

**变异验证**：把 `cleanup()` 还原成旧写法（迭代期删除 + 单档 TTL）后，
3 个用例立即变红 —— 确认用例真的锁住缺陷，而非空转。

### 验证（端到端，内存回落）

隔离实例灌 890 条（首页渲染树 35KB），连发 400 次 `GET /` 模拟健康检查：

```
修复版： 基线 26.1 → 400 次后 44.8 → +30s 90.7 → +90s 40.8 → +120s 27.6 → 稳定 27.6 MB
                                                              ↑ 巡检回收，回落到基线
```

**回落即证据**：会话在短 TTL + 巡检周期后被回收。

> **诚实说明**：对照（修复前版本）在同一实验里内存**也没明显增长**
> （稳定 25.7MB）。原因是本实验数据量仍小于生产 —— 生产 1756 会话 × 338KB = 608MB
> 才显性，而本实验每会话约 35KB 级。因此**端到端对照未能复现量级差异**，
> 修复正确性主要由**单测 + 变异验证**支撑（那部分是可判定的）。
> 教训：验证这类泄漏必须以**生产同量级数据**跑，否则对照组与实验组都无信号。

## 六、遗留

- 生产需重新部署才能生效（cjxt 修复 + 健康检查改动）。
- 已合并但未部署的另一项：堆水位主动 dump 钩子
  （`CHRONOLOG_HEAP_DUMP_THRESHOLD_PCT`，默认关闭）+ tsdb 0.3.5。

