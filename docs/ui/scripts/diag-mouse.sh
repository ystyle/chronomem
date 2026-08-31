#!/bin/bash
# 诊断3：精确坐标真实鼠标点击（CDP mouse move/down/up）
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-diag3

echo "== [1] open =="
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3

agent-browser eval "
window.__hit = null;
document.addEventListener('click', (e) => {
  window.__hit = {x: e.clientX, y: e.clientY, tag: e.target.tagName, cls: String(e.target.className).slice(0,60), inNav: !!e.target.closest('[data-action-click]')};
}, true);
'ok'" 2>&1 | tail -1

echo "== [2] 读塔视图菜单中心坐标 =="
CENTER=$(agent-browser eval "
const n = Array.from(document.querySelectorAll('.ui-nav')).find(x=>x.textContent.includes('塔视图'));
const r = n.getBoundingClientRect();
JSON.stringify({x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2)});
" 2>&1 | tail -1)
echo "center=$CENTER"
CX=$(echo "$CENTER" | grep -o '"x":[0-9]*' | cut -d: -f2)
CY=$(echo "$CENTER" | grep -o '"y":[0-9]*' | cut -d: -f2)

echo "== [3] 精确坐标真实点击 ($CX,$CY) =="
agent-browser mouse move $CX $CY 2>&1 | tail -1
agent-browser mouse down 2>&1 | tail -1
agent-browser mouse up 2>&1 | tail -1
sleep 2

echo "== [4] 结果 =="
agent-browser eval "JSON.stringify({hit: window.__hit, path: location.pathname})" 2>&1 | tail -1
agent-browser screenshot --screenshot-dir /home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots 2>&1 | tail -1
