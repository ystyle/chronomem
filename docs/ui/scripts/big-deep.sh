#!/bin/bash
# 大桶真实点击实测：bigdemo（6000 条）塔视图 → 桶 drill（计时 + 截图）
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-big
OUT=/home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots/tour
agent-browser close --all >/dev/null 2>&1; sleep 1
agent-browser open http://127.0.0.1:8921 >/dev/null 2>&1; sleep 4
nav() { agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[$1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"'; }
click_at() { agent-browser mouse move "$1" "$2" >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1; }
# 进塔视图
NC=$(nav 1); click_at $(echo "$NC" | cut -d' ' -f1) $(echo "$NC" | cut -d' ' -f2)
sleep 3
echo "tower=$(agent-browser eval "location.pathname" 2>&1 | tail -1 | tr -d '"')"
# 类型选择 bigdemo（EP Select：点开 → 找 bigdemo 选项 → 点它）
agent-browser eval "(() => { const s=document.querySelector('.el-select__wrapper')||document.querySelector('.el-select'); if(s){s.click();} return 'opened'; })()" >/dev/null 2>&1
sleep 1
BD=$(agent-browser eval "(() => { const opt=Array.from(document.querySelectorAll('.el-select-dropdown__item')).find(x=>x.textContent.includes('bigdemo')); if(!opt) return 'none'; const r=opt.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"')
echo "bigdemo-opt=[$BD]"
if [ "$BD" != "none" ]; then click_at $(echo "$BD" | cut -d' ' -f1) $(echo "$BD" | cut -d' ' -f2); fi
sleep 3
echo "sel=$(agent-browser eval "JSON.stringify({sel: (document.querySelector('.el-select__selected-item')||{textContent:''}).textContent, buckets: Array.from(document.querySelectorAll('.ui-bucket')).slice(0,3).map(b=>b.textContent.trim().slice(0,16))})" 2>&1 | tail -1)"
agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1 && echo shot1
# 滚桶+点击第一个桶（计时）
agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); if(!b) return; b.scrollIntoView({block:'center'}); })()" >/dev/null 2>&1
sleep 1
agent-browser eval "(() => { window.__t0 = performance.now(); const iv=setInterval(()=>{ const d=document.querySelector('.ui-drill'); if(d && d.querySelector('.ui-point')){ window.__t1=performance.now(); clearInterval(iv);} },30); })()" >/dev/null 2>&1
BC=$(agent-browser eval "(() => { const b=document.querySelector('.ui-bucket'); const r=b.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"')
click_at $(echo "$BC" | cut -d' ' -f1) $(echo "$BC" | cut -d' ' -f2)
sleep 6
echo "drill=$(agent-browser eval "JSON.stringify({ms: Math.round((window.__t1||0)-(window.__t0||0)), head: (document.querySelector('.ui-drill')||{textContent:''}).textContent.slice(0,70), points: document.querySelectorAll('.ui-point').length})" 2>&1 | tail -1)"
agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1 && echo shot2