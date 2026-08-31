#!/bin/bash
# 诊断：真实点击事件是否到达页面 + 委托是否触发 + action 是否发出
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-diag

echo "== [1] open 页面 =="
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3

echo "== [2] 挂事件计数器 =="
agent-browser eval "
window.__evt = {click:0, mousedown:0, mouseup:0, bubbleClick:0, actionSent:0};
document.addEventListener('mousedown', () => window.__evt.mousedown++, true);
document.addEventListener('mouseup', () => window.__evt.mouseup++, true);
document.addEventListener('click', () => window.__evt.click++, true);
document.addEventListener('click', (e) => {
  const el = e.target.closest && e.target.closest('[data-action-click]');
  if (el) window.__evt.bubbleClick++;
}, false);
['mousedown','mouseup','click'].forEach(t => {
  if (document.getElementById('app')) {
    document.getElementById('app').addEventListener(t, () => { window.__evt[t] = (window.__evt[t]||0)+0; });
  }
});
'ok'" 2>&1 | tail -1

echo "== [3] 找菜单元素 =="
agent-browser eval "JSON.stringify(Array.from(document.querySelectorAll('.ui-nav')).map(n=>({t:n.textContent.trim(), act:n.getAttribute('data-action-click')})))" 2>&1 | tail -1

echo "== [4] agent-browser 真实点击 =="
agent-browser find text 塔视图 click 2>&1 | tail -1
sleep 2

echo "== [5] 计数器与 URL =="
agent-browser eval "JSON.stringify({evt: window.__evt, path: location.pathname})" 2>&1 | tail -1
