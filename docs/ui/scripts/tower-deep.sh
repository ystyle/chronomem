#!/bin/bash
# 塔视图深测：桶下钻（真实点击）+ 层切换 + 截图
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-tower-test
OUT=/home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots/tour
agent-browser close --all >/dev/null 2>&1; sleep 1
agent-browser open http://127.0.0.1:8921 >/dev/null 2>&1; sleep 4

nav() { agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[$1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"'; }
click_at() { agent-browser mouse move "$1" "$2" >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1; }

NC=$(nav 1); click_at $(echo "$NC" | cut -d' ' -f1) $(echo "$NC" | cut -d' ' -f2)
sleep 3
echo "tower path=$(agent-browser eval "location.pathname" 2>&1 | tail -1 | tr -d '"')"
echo "buckets=$(agent-browser eval "JSON.stringify(Array.from(document.querySelectorAll('.ui-bucket')).map(b=>b.textContent.trim().slice(0,14)))" 2>&1 | tail -1)"
# 滚动桶进入视口
agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); if (!b) return; const r=b.getBoundingClientRect(); if (r.top<60||r.bottom>window.innerHeight-10) b.scrollIntoView({block:'center'}); })()" >/dev/null 2>&1
sleep 1
# 点击第一个桶
BC=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"')
click_at $(echo "$BC" | cut -d' ' -f1) $(echo "$BC" | cut -d' ' -f2)
sleep 4
echo "drill=$(agent-browser eval "JSON.stringify({head: (document.querySelector('.ui-drill')||{textContent:''}).textContent.slice(0,80), points: document.querySelectorAll('.ui-point').length})" 2>&1 | tail -1)"
agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1 && echo "shot-tower-drill ok"
# 层切换：点击 day 层（塔中心区）
agent-browser eval "document.querySelector('.ui-tower-center').scrollIntoView({block:'center'})" >/dev/null 2>&1
sleep 1
LC=$(agent-browser eval "(() => { const n=Array.from(document.querySelectorAll('.ui-layer')).find(x=>x.textContent.includes('day')); if(!n) return 'none'; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"')
echo "layer-center=[$LC]"
click_at $(echo "$LC" | cut -d' ' -f1) $(echo "$LC" | cut -d' ' -f2)
sleep 3
echo "after-layer=$(agent-browser eval "JSON.stringify({active: (document.querySelector('.ui-layer.l-active')||{textContent:''}).textContent.slice(0,12), path: location.pathname})" 2>&1 | tail -1)"
agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1 && echo "shot-layer ok"