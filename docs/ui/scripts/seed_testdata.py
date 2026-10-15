#!/usr/bin/env python3
"""灌测试数据到「隔离测试实例」（默认 18901）。

覆盖 UI 各界面所需场景：
- worklog：多天 / 多项目 / 长 outcome（看全内容）/ 不同 status
- 多粒度类型：high_freq(10min→1h→day)、coarse(day→week→month)
- 分组维度类型：proj/decisions（summary_group_by=proj）
- tags 组合、超长文本、emoji/中文混合
- 空类型（验证空态渲染）

**追加写拒绝乱序**：tsdb 的 append 要求 ts 递增，乱序会被静默拒绝 →
本脚本先把全部条目按 ts 升序排好再逐条写入。

**安全闸门**：默认目标为隔离端口 18901，硬拒生产 8900 / 8901 / bench 18900。
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

TZ = timezone(timedelta(hours=8))
FORBIDDEN_PORTS = {8900, 8901, 18900}

TYPES = [
    ("high_freq", "高频事件流：分钟级切片，验证多粒度塔层", ["10min", "1h", "day"], None),
    ("coarse", "低频长周期：日/周/月，验证粗粒度层", ["day", "week", "month"], None),
    ("proj/decisions", "按项目分组的决策记录（summary_group_by=proj）", ["day", "week"], ["proj"]),
    ("empty_type", "空类型：验证空态渲染（无条目/无桶/无摘要）", ["day", "week"], None),
    ("long_text", "超长文本：验证记忆内容能否看全（截断/展开/滚动）", ["day"], None),
]


def rpc(url, tool, args, rid):
    body = json.dumps({
        "jsonrpc": "2.0", "id": rid, "method": "tools/call",
        "params": {"name": tool, "arguments": args},
    }).encode()
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=60) as r:
        raw = r.read().decode()
    for line in raw.splitlines():
        if line.startswith("data:"):
            raw = line[5:].strip()
            break
    return json.loads(raw)


def text_of(resp):
    """取工具返回文本；JSON-RPC 层错误（工具抛异常）转为显式失败标记。

    说明：工具内抛异常时服务端回的是 error 对象而非 result，旧版这里直接
    json.dumps(resp)[:300] 当文本返回 → 调用方把「缺少参数 type」这类错误
    当普通文本打印，truncate 静默失败，直到后续 append 全被 out-of-order
    拒绝才暴露（表现为「TRUNCATE 不重置水位」的假象）。
    """
    if "error" in resp:
        return "ERROR: " + str(resp["error"].get("message", resp["error"]))[:300]
    try:
        return resp["result"]["content"][0]["text"]
    except Exception:
        return "ERROR: 无法解析响应 " + json.dumps(resp)[:300]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:18901/mcp")
    ap.add_argument("--days", type=int, default=21)
    ap.add_argument("--reset", action="store_true", help="先 TRUNCATE 各类型（重跑幂等）")
    args = ap.parse_args()

    u = urllib.parse.urlparse(args.url)
    if u.port in FORBIDDEN_PORTS:
        print(f"拒绝：{args.url} 指向非隔离端口 {u.port}"
              f"（生产 8900/8901、bench 18900 一律禁用）")
        sys.exit(2)

    rid = [0]

    def call(tool, **kwargs):
        rid[0] += 1
        return text_of(rpc(args.url, tool, kwargs, rid[0]))

    now = datetime.now(TZ)
    projects = ["chronomem", "cjreg", "cjxt", "tsdb-cj", "mcp-cj", "llm_api"]
    branches = ["feat/web-ui", "master", "fix/oom", "feat/timeline"]
    statuses = ["完成", "阶段完成", "进行中"]

    long_outcome = (
        "【交付】完成 UI 全面评审与修复：①暗色主题下所有下拉/弹层组件补齐深色变量覆盖；"
        "②记忆内容截断问题改为可展开全文 + 弹窗查看；③塔视图桶卡片补计数与层级提示。"
        "长文本测试专用段落，用于验证超长 outcome 在时间流、下钻面板、查询结果中是否可完整查看。"
        "继续填充以便触发截断逻辑：abcdefghijklmnopqrstuvwxyz0123456789 " * 8
    )
    long_decisions = (
        "①下拉深色：EP 的 popper teleport 到 body，仅覆盖 :root 不足以命中外层 popper，"
        "需同时覆盖 .el-popper / .el-select-dropdown 的 background 与 border；"
        "②内容看全：截断必须给出口（展开/弹窗），否则等于数据不可读；" * 5
    )

    # ---------- 1) 建类型 ----------
    # 已存在（重跑）不算错：工具返回「类型已存在」或 JSON-RPC error 都属预期
    for name, desc, levels, group in TYPES:
        kw = {"name": name, "description": desc, "levels": levels}
        if group:
            kw["summary_group_by"] = group
        r = call("mem/type_create", **kw)
        if "已创建" not in r and "已存在" not in r and "ERROR" not in r:
            print(f"  type_create {name}: {r}")
        else:
            print(f"  type_create {name}: {'已存在（跳过）' if '已存在' in r else '已创建'}")

    if args.reset:
        # worklog 由服务启动时播种，同样清空以保证重跑幂等。
        # 参数名是 type（不是 name）——传错会得到「缺少参数 type」而 truncate 完全不执行。
        for name in ["worklog"] + [t[0] for t in TYPES]:
            r = call("mem/truncate", type=name)
            if "已清空" not in r:
                print(f"  reset {name}: 失败 → {r}")
                sys.exit(3)
            print(f"  reset {name}: {r}")

    # ---------- 2) 收集条目（全部带显式 ts），最后统一升序写 ----------
    items = []  # (ts, type, payload, tags)

    def add(ts, type_name, payload, tags):
        items.append((ts, type_name, payload, tags))

    n_long = 0
    for d in range(args.days):
        day = now - timedelta(days=d)
        for pi, proj in enumerate(projects):
            if (d + pi) % 3 != 0:
                continue
            ts = int(day.replace(hour=9 + (pi % 9), minute=17, second=0,
                                 microsecond=0).timestamp() * 1000)
            n_long += 1
            big = (n_long % 7 == 0)
            add(ts, "worklog", {
                "task": f"{proj} 评审任务（{args.days - d} 天前）",
                "status": statuses[(d + pi) % 3],
                "outcome": long_outcome if big else
                           f"完成 {proj} 的界面评审项 {pi + 1}：调整深色变量、修复截断、回归用例通过。",
                "decisions": long_decisions if big else "优先修可读性，再谈观感。",
                "next": "补单测；多分辨率回归。",
            }, {"proj": proj, "branch": branches[(d + pi) % 4], "agent": "seed"})

    for i in range(90):
        t = now - timedelta(minutes=i * 23)
        add(int(t.timestamp() * 1000), "high_freq",
            {"task": f"心跳 {i}", "status": "完成",
             "outcome": f"第 {i} 次探活，延迟 {20 + (i % 30)}ms。"},
            {"proj": projects[i % len(projects)], "kind": "probe"})

    for i in range(14):
        t = now - timedelta(days=i * 8)
        add(int(t.timestamp() * 1000), "coarse",
            {"task": f"长周期回顾 {i}", "status": "完成",
             "outcome": "长周期条目，用于验证 week/month 层与粗粒度桶。"},
            {"proj": "chronomem", "period": f"p{i}"})

    for i, proj in enumerate(projects):
        for j in range(3):
            t = now - timedelta(days=j * 3 + i)
            add(int(t.timestamp() * 1000), "proj/decisions",
                {"task": f"{proj} 决策 {j}", "status": "完成",
                 "outcome": f"{proj} 选择方案 {'ABC'[j % 3]}，理由：可维护性优先。",
                 "decisions": f"方案 {'ABC'[j % 3]} 胜出。"},
                {"proj": proj, "kind": "decision"})

    huge = ("超长记忆内容测试。" * 40 + "\n\n" +
            "第二段：包含换行与中文标点，验证渲染是否保留换行。" * 20)
    for i in range(5):
        t = now - timedelta(hours=i * 5)
        add(int(t.timestamp() * 1000), "long_text",
            {"task": f"长文条目 {i}", "status": "完成",
             "outcome": huge, "decisions": huge, "next": huge},
            {"proj": "chronomem", "kind": "longform", "emoji": "🧪🎯"})

    for i in range(6):
        t = now - timedelta(hours=i * 3)
        add(int(t.timestamp() * 1000), "worklog",
            {"task": f"标签组合测试 {i}", "status": "进行中",
             "outcome": "验证多 tag 换行与徽章渲染，含一个超长 tag 键。"},
            {"proj": projects[i % len(projects)], "branch": branches[i % 4],
             "session": f"dsh-{1000 + i}", "agent": "dsh-lead",
             "goal": f"g-{i}", "very_long_tag_key_name": "a" * 40})

    # ---------- 3) 升序写入（append 拒绝乱序） ----------
    items.sort(key=lambda x: x[0])
    ok = 0
    fails = []
    seen_ts = {}
    for ts, tname, payload, tags in items:
        # 同 ts 会互相覆盖：给同 (类型,ts) 的第二条起 +1ms
        k = (tname, ts)
        if k in seen_ts:
            ts += 1
            while (tname, ts) in seen_ts:
                ts += 1
        seen_ts[(tname, ts)] = True
        r = call("mem/append", type=tname, payload=payload, ts=ts, tags=tags)
        if r.startswith("已追加"):
            ok += 1
        else:
            fails.append((tname, ts, r[:160]))

    print(f"\n待写 {len(items)} 条，成功 {ok} 条")
    if fails:
        # 全量失败时只打印前若干条（避免刷屏），但必须让退出码非 0：
        # 静默失败会把「脚本本身写错」误诊成「存储层缺陷」。
        print(f"失败 {len(fails)} 条，前 5 条：")
        for tname, ts, r in fails[:5]:
            print(f"  {tname} ts={ts} → {r}")

    # ---------- 4) 核对 ----------
    print()
    counts = {}
    for name, *_ in TYPES:
        info = call("mem/type_info", name=name)
        line = [x for x in info.splitlines() if "条目数" in x]
        counts[name] = line[0] if line else info[:80]
        print(f"{name}: {counts[name]}")

    if fails:
        sys.exit(4)


if __name__ == "__main__":
    main()
