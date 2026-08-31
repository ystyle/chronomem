#!/bin/bash
# 忆时塔 Web UI · 塔视图真实点击测试（agent-browser，CDP 真实鼠标事件）
# 用法：bash docs/ui/scripts/test-tower-click.sh
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-flow
OUT=/home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots
mkdir -p "$OUT"

echo "== [1] open 页面 =="
agent-browser open http://127.0.0.1:8901 2>&1 | tail -1
sleep 3
echo "== [2] 页面状态 =="
agent-browser eval "JSON.stringify({url: location.href, appKids: (document.getElementById('app')||{children:[]}).children.length, navs: Array.from(document.querySelectorAll('.ui-nav')).map(n=>n.textContent.trim())})" 2>&1 | tail -1

echo "== [3] 真实点击菜单「塔视图」 =="
agent-browser find text 塔视图 click 2>&1 | tail -2
sleep 2
echo "== [4] 点击后 URL 与桶区 =="
agent-browser eval "JSON.stringify({path: location.pathname, buckets: Array.from(document.querySelectorAll('.ui-bucket')).map(b=>b.textContent.trim()), bActions: Array.from(document.querySelectorAll('.ui-bucket')).slice(0,3).map(b=>b.getAttribute('data-action-click'))})" 2>&1 | tail -1

echo "== [5] 真实点击第一个时间桶 =="
agent-browser click ".ui-bucket" 2>&1 | tail -2
sleep 3
echo "== [6] 点击后 drill 面板状态 =="
agent-browser eval "JSON.stringify({drillText: (document.querySelector('.ui-drill')||{textContent:''}).textContent.slice(0,120), drillKids: (document.querySelector('.ui-drill')||{children:[]}).children.length, selBuckets: Array.from(document.querySelectorAll('.ui-bucket.sel')).map(b=>b.textContent.trim())})" 2>&1 | tail -1

echo "== [7] 截图 =="
agent-browser screenshot --screenshot-dir "$OUT" 2>&1 | tail -1
