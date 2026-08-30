#!/bin/bash
# 5 轮统计：菜单点击 + 桶点击成功率
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-stats
agent-browser close --all >/dev/null 2>&1
sleep 1
PASS_MENU=0; PASS_BUCKET=0
for i in 1 2 3 4 5; do
  agent-browser open http://192.168.3.6:8901 >/dev/null 2>&1
  sleep 3
  # 点击菜单（塔视图）
  CX=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
  CY=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
  agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
  sleep 2
  P=$(agent-browser eval "location.pathname" 2>&1 | tail -1 | tr -d '\"')
  if [ "$P" = "/tower" ]; then PASS_MENU=$((PASS_MENU+1)); MSTAT="OK"; else MSTAT="FAIL($P)"; fi
  # 滚桶进视口并点击
  agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); if (!b) return; const r=b.getBoundingClientRect(); if (r.top<60||r.bottom>window.innerHeight-10) b.scrollIntoView({block:'center'}); })()" >/dev/null 2>&1
  sleep 1
  BX=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
  BY=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
  agent-browser mouse move $BX $BY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
  sleep 2
  S=$(agent-browser eval "JSON.stringify({sel: document.querySelectorAll('.ui-bucket.sel').length, n: document.querySelectorAll('.ui-bucket').length})" 2>&1 | tail -1)
  if echo "$S" | grep -q 'sel.:1'; then PASS_BUCKET=$((PASS_BUCKET+1)); BSTAT="OK $S"; else BSTAT="FAIL $S"; fi
  echo "round$i menu=$MSTAT bucket=$BSTAT"
done
echo "== RESULT menu=$PASS_MENU/5 bucket=$PASS_BUCKET/5 =="