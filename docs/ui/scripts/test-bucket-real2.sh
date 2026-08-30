#!/bin/bash
# 简化取值：eval 直接回数字
getx() { agent-browser eval "Math.round(document.querySelectorAll('.ui-nav')[$1].getBoundingClientRect().left + document.querySelectorAll('.ui-nav')[$1].getBoundingClientRect().width/2)" 2>&1 | tail -1; }
() { agent-browser eval "Math.round(document.querySelectorAll('.ui-nav')[$1].getBoundingClientRect().top + document.querySelectorAll('.ui-nav')[$1].getBoundingClientRect().height/2)" 2>&1 | tail -1; }
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-bucket2
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3
# 菜单 idx 1 = 塔视图
CX=$ 1); CY=$(gety 1)
echo "nav center=($CX,$CY)"
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 2
agent-browser eval "location.pathname" 2>&1 | tail -1
# 桶中心
BX=$(agent-browser eval "b=document.querySelector('.ui-bucket'); Math.round(b.getBoundingClientRect().left + b.getBoundingClientRect().width/2)" 2>&1 | tail -1)
BY=$(agent-browser eval "b=document.querySelector('.ui-bucket'); Math.round(b.getBoundingClientRect().top + b.getBoundingClientRect().height/2)" 2>&1 | tail -1)
echo "bucket center=($BX,$BY)"
agent-browser mouse move $BX $BY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 3
agent-browser eval "JSON.stringify({drillLen: (document.querySelector('.ui-drill')||{textContent:''}).textContent.length, drillHead: (document.querySelector('.ui-drill')||{textContent:''}).textContent.slice(0,90), sel: document.querySelectorAll('.ui-bucket.sel').length, points: document.querySelectorAll('.ui-point').length})" 2>&1 | tail -1
agent-browser screenshot --screenshot-dir /home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots 2>&1 | tail -1