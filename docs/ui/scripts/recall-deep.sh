#!/bin/bash
# 回想页深测：Tab 切换(原始/摘要) + 粒度 radio + 查询按钮 + 窗口摘要桶
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-recall-test
OUT=/home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots/tour
agent-browser close --all >/dev/null 2>&1; sleep 1
agent-browser open http://127.0.0.1:8921 >/dev/null 2>&1; sleep 4
nav() { agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[$1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"'; }
click_at() { agent-browser mouse move "$1" "$2" >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1; }
# 进回想
NC=$(nav 2); click_at $(echo "$NC" | cut -d' ' -f1) $(echo "$NC" | cut -d' ' -f2)
sleep 3
echo "path=$(agent-browser eval "location.pathname" 2>&1 | tail -1 | tr -d '"')"
# 找 Tabs（el-tabs__item）—— 点击"语义回顾 · 窗口摘要" tab
TC=$(agent-browser eval "(() => { const t=Array.from(document.querySelectorAll('.el-tabs__item')).find(x=>x.textContent.includes('语义回顾')); if(!t) return 'none'; const r=t.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"')
echo "summary-tab=[$TC]"
click_at $(echo "$TC" | cut -d' ' -f1) $(echo "$TC" | cut -d' ' -f2)
sleep 3
echo "after-tab=$(agent-browser eval "JSON.stringify({active: (document.querySelector('.el-tabs__item.is-active')||{textContent:''}).textContent.slice(0,20), hasRadio: document.querySelectorAll('.el-radio').length, hasSelect: document.querySelectorAll('.el-select').length})" 2>&1 | tail -1)"
agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1 && echo "shot-recall-summary ok"
# 切回原始 tab
TC2=$(agent-browser eval "(() => { const t=Array.from(document.querySelectorAll('.el-tabs__item')).find(x=>x.textContent.includes('精确回想')); if(!t) return 'none'; const r=t.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"')
click_at $(echo "$TC2" | cut -d' ' -f1) $(echo "$TC2" | cut -d' ' -f2)
sleep 3
echo "back-raw=$(agent-browser eval "JSON.stringify({active: (document.querySelector('.el-tabs__item.is-active')||{textContent:''}).textContent.slice(0,20), rows: document.querySelectorAll('.ui-res-row').length})" 2>&1 | tail -1)"
agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1 && echo "shot-recall-raw ok"