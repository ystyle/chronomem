#!/bin/bash
# 塔视图时间桶：精确坐标真实点击 → drill 面板
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-bucket

echo "== [1] open =="
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3

echo "== [2] 点菜单进塔视图 =="
C=$(agent-browser eval "
const n = Array.from(document.querySelectorAll('.ui-nav')).find(x=>x.textContent.includes('塔视图'));
const r = n.getBoundingClientRect();
JSON.stringify({x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2)})" 2>&1 | tail -1)
CX=$(python3 -c "import sys,re; m=re.findall(r'x\":(\d+)', sys.stdin.read()); print(m[0])" <<<"$C")
CY=$(python3 -c "import sys,re; m=re.findall(r'y\":(\d+)', sys.stdin.read()); print(m[0])" <<<"$C")
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 2

echo "== [3] 读第一个桶中心 =="
B=$(agent-browser eval "
const b = document.querySelector('.ui-bucket');
if (!b) { JSON.stringify({err:'no bucket'}); } else {
const r = b.getBoundingClientRect();
JSON.stringify({x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2), key: b.textContent.trim().slice(0,30)});
}" 2>&1 | tail -1)
echo "bucket=$B"
BX=$(python3 -c "import sys,re; m=re.findall(r'x\":(\d+)', sys.stdin.read()); print(m[0] if m else '')" <<<"$B")
BY=$(python3 -c "import sys,re; m=re.findall(r'y\":(\d+)', sys.stdin.read()); print(m[0] if m else '')" <<<"$B")

echo "== [4] 精确坐标真实点击桶 ($BX,$BY) =="
agent-browser mouse move $BX $BY 2>&1 | tail -1
agent-browser mouse down 2>&1 | tail -1
agent-browser mouse up 2>&1 | tail -1
sleep 3

echo "== [5] drill 面板检查 =="
agent-browser eval "JSON.stringify({drillLen: (document.querySelector('.ui-drill')||{textContent:''}).textContent.length, drillHead: (document.querySelector('.ui-drill')||{textContent:''}).textContent.slice(0,80), selCount: document.querySelectorAll('.ui-bucket.sel').length, pointCards: document.querySelectorAll('.ui-point').length})" 2>&1 | tail -1
agent-browser screenshot --screenshot-dir /home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots 2>&1 | tail -1
