#!/bin/bash
# 完整链路：open → 菜单点击 → 桶属性 → 桶真实点击 → sel/hit
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-full
agent-browser close --all >/dev/null 2>&1
sleep 1
agent-browser open http://127.0.0.1:8901 >/dev/null 2>&1
sleep 4
echo "STEP0: $(agent-browser get url 2>&1 | tail -1) nav=$(agent-browser eval "document.querySelectorAll('.ui-nav').length" 2>&1 | tail -1)"
CX=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
CY=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
echo "STEP1: nav center=($CX,$CY)"
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 2
echo "STEP2: path=$(agent-browser eval "location.pathname" 2>&1 | tail -1)"
agent-browser eval "(() => { const bs=document.querySelectorAll('.ui-bucket'); window.__binfo = {n: bs.length, acts: Array.from(bs).slice(0,2).map(b=>b.getAttribute('data-action-click')), html: (bs[0]||{outerHTML:''}).outerHTML.slice(0,200)}; })()" >/dev/null 2>&1
echo "STEP3: $(agent-browser eval "JSON.stringify(window.__binfo)" 2>&1 | tail -1)"
# 若桶不在视口滚入
agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); if (!b) return 'nobucket'; const r=b.getBoundingClientRect(); if (r.top < 60 || r.bottom > window.innerHeight-10) b.scrollIntoView({block:'center'}); return 'ok'; })()" 2>&1 | tail -1
sleep 1
BX=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
BY=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
echo "STEP4: bucket center=($BX,$BY)"
agent-browser eval "(() => { window.__hit=null; document.addEventListener('click', (e) => { window.__hit = {tag: e.target.tagName, cls: String(e.target.className).slice(0,40), act: (e.target.closest('[data-action-click]')||{getAttribute:()=>null}).getAttribute ? (e.target.closest('[data-action-click]')||{}).getAttribute('data-action-click') : null}; }, true); })()" >/dev/null 2>&1
agent-browser mouse move $BX $BY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 3
echo "STEP5: hit=$(agent-browser eval "JSON.stringify(window.__hit)" 2>&1 | tail -1)"
echo "STEP6: $(agent-browser eval "JSON.stringify({sel: document.querySelectorAll('.ui-bucket.sel').length, drill: (document.querySelector('.ui-drill')||{textContent:''}).textContent.slice(0,60)})" 2>&1 | tail -1)"
agent-browser screenshot --screenshot-dir /home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots >/dev/null 2>&1 && echo "shot ok"