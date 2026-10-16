#!/usr/bin/env python3
"""给 README 截 Web 控制台各页面图（隔离实例，用测试数据）。

用法：
    python3 docs/ui/scripts/readme_shots.py            # 默认 127.0.0.1:18901
    BASE=http://127.0.0.1:8900 python3 .../readme_shots.py

产出：docs/assets/*.png（宽 1440，页面顶部长图 + 关键交互态）
**只对隔离实例截图**：README 是公开文档，不使用生产数据（真实记忆内容）。
"""
import glob
import os
import subprocess
import sys
import time
import urllib.parse

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
OUT = os.path.join(REPO, "docs", "assets")
BASE = os.environ.get("BASE", "http://127.0.0.1:18901")
FORBIDDEN_PORTS = {8900, 8901, 18900}   # 生产 / 生产 UI / bench 实例

W, H = 1440, 900
SESSION = os.environ.get("SESSION", "cm-readme")
ENV = dict(os.environ, AGENT_BROWSER_SOCKET_DIR="/tmp/ab-cm-readme",
           AGENT_BROWSER_SESSION=SESSION)


def ab(*args):
    r = subprocess.run(["agent-browser", *args], capture_output=True,
                       text=True, env=ENV, timeout=120)
    return ((r.stdout or "") + (r.stderr or "")).strip()


def js(expr):
    out = ab("eval", expr)
    return out.strip('"')


def goto(path, wait=5):
    ab("open", BASE + path)
    time.sleep(wait)
    ab("set", "viewport", str(W), str(H))
    time.sleep(2)


def shot(name):
    os.makedirs(OUT, exist_ok=True)
    before = set(glob.glob(os.path.join(OUT, "screenshot-*.png")))
    ab("screenshot", "--screenshot-dir", OUT)
    new = set(glob.glob(os.path.join(OUT, "screenshot-*.png"))) - before
    if not new:
        cand = glob.glob(os.path.join(OUT, "screenshot-*.png"))
        if not cand:
            print(f"  !! {name}: 未生成截图")
            return
        new = {max(cand, key=os.path.getmtime)}
    src = new.pop()
    dst = os.path.join(OUT, name + ".png")
    if os.path.exists(dst):
        os.remove(dst)
    os.rename(src, dst)
    print(f"  ✓ {name}.png  ({os.path.getsize(dst)//1024} KB)")


def main():
    port = urllib.parse.urlparse(BASE).port
    if port in FORBIDDEN_PORTS:
        print(f"拒绝：{BASE} 非隔离端口（{sorted(FORBIDDEN_PORTS)} 为生产/bench）")
        sys.exit(2)

    ab("close", "--all")
    time.sleep(1)

    # 1) 总览
    goto("/")
    shot("console-overview")

    # 2) 塔视图（默认已选类型，展示分层时间塔）
    goto("/tower", wait=6)
    shot("console-tower")

    # 3) 塔视图：点开类型下拉（展示暗色适配）
    goto("/tower", wait=6)
    ab("eval", "(()=>{const w=document.querySelector('.el-select__wrapper');"
               "if(w){w.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));w.click();}return 1})()")
    time.sleep(2)
    shot("console-tower-select")

    # 4) 塔视图：下钻（点第一个时间桶 → 右侧原始条目）
    goto("/tower", wait=6)
    ab("eval", "(()=>{const b=document.querySelector('.ui-bucket');"
               "if(b)b.dispatchEvent(new MouseEvent('click',{bubbles:true}));return 1})()")
    time.sleep(3)
    shot("console-tower-drill")

    # 5) 回想：精确回想（长内容带「展开全文」）
    goto("/recall", wait=6)
    ab("eval", "(()=>{const w=document.querySelector('.el-select__wrapper');"
               "if(w){w.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));w.click();}return 1})()")
    time.sleep(2)
    ab("eval", "(()=>{const it=[...document.querySelectorAll('.el-select-dropdown__item')]"
               ".find(i=>i.textContent.trim()==='long_text');"
               "if(it)it.dispatchEvent(new MouseEvent('click',{bubbles:true}));return 1})()")
    time.sleep(4)
    shot("console-recall")

    # 6) 语义总结
    goto("/summary", wait=6)
    shot("console-summary")

    # 7) 记忆类型（表格 + 创建弹窗）
    goto("/types", wait=6)
    shot("console-types")
    ab("eval", "(()=>{const b=[...document.querySelectorAll('.ui-btn')]"
               ".find(x=>x.textContent.includes('创建类型'));if(b)b.click();return 1})()")
    time.sleep(2)
    shot("console-types-dialog")

    # 8) 追加条目
    goto("/append", wait=6)
    shot("console-append")

    print(f"\n输出目录：{OUT}")


if __name__ == "__main__":
    main()
