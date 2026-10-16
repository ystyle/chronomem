# 凭据泄露：AiraXiv API key 进入公开仓库 — 2026-10-16

## 事实

`bench/airamcp.sh` 第 15 行曾以一个**内联兜底**的形式携带 AiraXiv 的 API key：

```bash
KEY="${AIRAXIV_API_KEY:-sk-KxsSMs…<redacted>}"
```

该文件随提交 **`5d90216`**（"实证论文提交 AiraXiv + 补 MCP 直连客户端"）进入版本库。

| 远程 | 是否含该提交 | 可见性 |
|---|---|---|
| `origin`（私有 Gitea） | **是** | 私有 |
| `atomgit` | **是** | 公开（匿名访问 http=200） |
| `github` | **是** | **PUBLIC** |

**该 key 在本记录写下时仍然有效**（对 AiraXiv 端点 `initialize` 返回 200）。

## 为什么当时没被发现

写这个脚本的目的正是为了绕开失效的 MCP 桥，而"内联兜底 key"是随手写下的便利写法 ——
脚本里还带着注释解释 MCP 的三步握手，却没有一句关于凭据来源的说明。
**便于硬编码的凭据，就是会被硬编码的凭据。**

## 已做的补救

1. **移除内联明文**，改为只从环境变量读取，且缺失时立即报错：

   ```bash
   KEY="${AIRAXIV_API_KEY:?AIRAXIV_API_KEY is not set — export it before running}"
   ```

   用法行同步改为 `AIRAXIV_API_KEY=... airamcp.sh <tool> '<json args>'`。

2. **新增 `bench/check_secrets.sh`**：扫描提交对象或暂存区里形如密钥的字面量
   （`sk-…` / `gh[pousr]_…` / `AKIA…` / PEM 私钥头），命中即拒绝并提示
   "旋转才是唯一真正的补救"。

3. **接入 CI**（`bench-harness` job 的「凭据扫描」步骤），使同类问题不再静默发生。

## 未解决 —— 必须由人处理

**旋转该 key 是唯一真正的补救。** 仅从工作树移除毫无用处：`5d90216` 仍在
三个远程的历史里，任何人 clone 都能取回。

在 key 被旋转之前，应视为已泄露。轮换步骤（由凭据持有者执行）：

1. 在 AiraXiv 侧吊销/重置该 API key；
2. 新 key 只放在 `$DSH_HOME/.env` 或 `AiraXiv` MCP 桥的插件配置里（该桥支持
   `AIRAXIV_API_KEY` 环境变量，见 `~/dsh-plugins/dsh-airaxiv-mcp/cordis.patch.yml`）；
3. 本地以 `AIRAXIV_API_KEY=... bench/airamcp.sh ...` 调用。

## 关于历史重写

从 git 历史中彻底抹除该 key（`git filter-repo` / BFG + 三仓强推）**不能替代旋转**：
公开仓库可能已被 fork、缓存或抓取，且历史重写会破坏所有协作者的克隆。
若决定同时重写历史，应**在旋转之后**做，并按"泄漏已发生"而非"泄漏已消除"来对待。

## 附带核实

同一轮扫描确认没有其它凭据进入版本库：`bench/results/real-corpus/token-survival.json`
与 `bench/token_survival.py` 的名字虽含 "token"，但指的是 **token 计数指标**，不含密钥（命中 0 处）。
