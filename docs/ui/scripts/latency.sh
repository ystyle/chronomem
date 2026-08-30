#!/bin/bash
# 点击响应时间实测：菜单进塔 + 桶下钻
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-lat
agent-browser close --all >/dev/null 2>&1; sleep 1
agent-browser open http://127.0.0.1:8901 >/dev/null 2>&1; sleep 4
# 菜单点击计时：挂 performance 记录
agent-browser eval "(() => { window.__t = {click: performance.now(), done: 0}; const iv = setInterval(() => { if (location.pathname === '/tower') { window.__t.done = performance.now(); clearInterval(iv); } }, 50); })()" >/dev/null 2>&1
CX=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
CY=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 4
echo "menu nav: $(agent-browser eval "(() => { const d = window.__t.done - window.__t.click; return JSON.stringify({ms: Math.round(d), path: location.pathname}); })()" 2>&1 | tail -1)"
# 桶点击计时：挂轮询 drill 文本出现
agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); if(b){const r=b.getBoundingClientRect(); if(r.top<60||r.bottom>window.innerHeight-10) b.scrollIntoView({block:'center'});} })()" >/dev/null 2>&1
sleep 1
agent-browser eval "(() => { window.__tb = {click: 0, done: 0}; const iv = setInterval(() => { const d = document.querySelector('.ui-drill'); if (d && d.textContent.indexOf('条') >= 0 && d.querySelector('.ui-point')) { window.__tb.done = performance.now(); clearInterval(iv); } }, 50); })()" >/dev/null 2>&1
BX=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
BY=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
agent-browser eval "(() => { window.__tb.click = performance.now(); })()" >/dev/null 2>&1
agent-browser mouse move $BX $BY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 5
echo "bucket drill: $(agent-browser eval "(() => { const t = window.__tb; return JSON.stringify({ms: Math.round(t.done - t.click), points: document.querySelectorAll('.ui-point').length}); })()" 2>&1 | tail -1)"
echo "=== server action ms ==="
docker logs chronomem 2>&1 | grep 'action done' | tail -4