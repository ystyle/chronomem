#!/bin/bash
# 时间桶精确坐标真实点击（IIFE 取坐标，避免全局重复声明）
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-bucket3
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3
CX=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
CY=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
echo "nav=($CX,$CY)"
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 2
echo "path=$(agent-browser eval "location.pathname" 2>&1 | tail -1)"
BX=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
BY=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
echo "bucket=($BX,$BY)"
agent-browser mouse move $BX $BY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 3
agent-browser eval "JSON.stringify({drillLen: (document.querySelector('.ui-drill')||{textContent:''}).textContent.length, drillHead: (document.querySelector('.ui-drill')||{textContent:''}).textContent.slice(0,90), sel: document.querySelectorAll('.ui-bucket.sel').length, points: document.querySelectorAll('.ui-point').length})" 2>&1 | tail -1
agent-browser screenshot --screenshot-dir /home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots 2>&1 | tail -1