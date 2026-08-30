#!/bin/bash
# 诊断4：精确坐标真实鼠标点击（修复解析）
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-diag4

echo "== [1] open =="
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3

agent-browser eval "
window.__hit = null;
document.addEventListener('click', (e) => {
  window.__hit = {x: e.clientX, y: e.clientY, tag: e.target.tagName, cls: String(e.target.className).slice(0,60), inNav: !!e.target.closest('[data-action-click]')};
}, true);
'ok'" 2>&1 | tail -1

CENTER=$(agent-browser eval "
const n = Array.from(document.querySelectorAll('.ui-nav')).find(x=>x.textContent.includes('塔视图'));
const r = n.getBoundingClientRect();
JSON.stringify({x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2)});
" 2>&1 | tail -1)
CX=$(python3 -c "import sys,json,re; raw=sys.stdin.read(); m=re.findall(r'\\\\\"x\\\\\":(\d+)', raw); print(m[0] if m else '')" <<<"$CENTER")
CY=$(python3 -c "import sys,json,re; raw=sys.stdin.read(); m=re.findall(r'\\\\\"y\\\\\":(\d+)', raw); print(m[0] if m else '')" <<<"$CENTER")
echo "center=($CX,$CY)"

echo "== [2] 精确坐标真实点击 =="
agent-browser mouse move $CX $CY 2>&1 | tail -1
agent-browser mouse down 2>&1 | tail -1
agent-browser mouse up 2>&1 | tail -1
sleep 2

echo "== [3] 结果 =="
agent-browser eval "JSON.stringify({hit: window.__hit, path: location.pathname})" 2>&1 | tail -1

echo "== [4] 若已进塔视图，读桶区 =="
agent-browser eval "JSON.stringify({buckets: Array.from(document.querySelectorAll('.ui-bucket')).length, sample: Array.from(document.querySelectorAll('.ui-bucket')).slice(0,3).map(b=>b.textContent.trim())})" 2>&1 | tail -1
