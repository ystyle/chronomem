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

## 五、修复方向（在 cjxt 侧，属该仓职责）

1. **必须**：让 `SessionManager.cleanup()` 被周期调用（或在 `servePage`/WS 关闭路径即时回收）；
   否则 TTL 形同虚设。
2. 建议：`servePage` 对**未建立 WS 的会话**设短 TTL（健康检查这类一次性请求不该长期驻留）。
3. 建议：`cleanup()` 内**边遍历边删除 HashMap** 是危险写法（可能跳过/未定义），
   应先收集过期 key 再逐个 remove（`clearAll()` 就是正确写法，可参照）。
4. 健康检查改探 `/mcp`（顺带缓解第 4 步的连接累积）。

> chronomem 侧可做的缓解：健康检查改探 `/mcp`（不走 UI 会话路径）。
> 根治需改 cjxt（本仓为其消费者，适配层无法修 Session 生命周期）。
