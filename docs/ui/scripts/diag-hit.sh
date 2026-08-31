#!/bin/bash
# 诊断2：CDP 真实点击命中的元素究竟是什么
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-diag2

echo "== [1] open =="
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3

echo "== [2] 记录点击 target =="
agent-browser eval "
window.__hit = null;
document.addEventListener('click', (e) => {
  window.__hit = {x: e.clientX, y: e.clientY, tag: e.target.tagName, cls: String(e.target.className).slice(0,80), inNav: !!e.target.closest('.ui-nav'), inApp: document.getElementById('app').contains(e.target)};
}, true);
'ok'" 2>&1 | tail -1

echo "== [3] 菜单元素几何信息 =="
agent-browser eval "
const n = Array.from(document.querySelectorAll('.ui-nav')).find(x=>x.textContent.includes('塔视图'));
const r = n ? n.getBoundingClientRect() : null;
const el = document.elementFromPoint ? document.elementFromPoint(r ? r.left + r.width/2 : 0, r ? r.top + r.height/2 : 0) : null;
JSON.stringify({rect: r ? {x:r.left,y:r.top,w:r.width,h:r.height} : null, atPoint: el ? el.tagName + '.' + String(el.className).slice(0,60) : null, side: (document.querySelector('.ui-side')||{getBoundingClientRect:()=>null}).getBoundingClientRect()})" 2>&1 | tail -1

echo "== [4] agent-browser 真实点击 =="
agent-browser find text 塔视图 click 2>&1 | tail -1
sleep 1
echo "== [5] 命中详情 =="
agent-browser eval "JSON.stringify(window.__hit)" 2>&1 | tail -1
