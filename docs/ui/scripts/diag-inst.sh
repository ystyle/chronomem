#!/bin/bash
# 检测 CangjieUI 实例数量 + 原始 WS 帧
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-inst
agent-browser close --all >/dev/null 2>&1
sleep 1
agent-browser open http://127.0.0.1:8901 --init-script /home/ystyle/Projects/Cangjie/chronomem/docs/ui/scripts/count-inst.js >/dev/null 2>&1
sleep 4
echo "insts=$(agent-browser eval "JSON.stringify({n: window.__insts, sids: window.__instSids, uiWs: window.ui && window.ui.ws ? window.ui.ws.readyState : null})" 2>&1 | tail -1)"
# 原始帧监听
agent-browser eval "(() => { window.__raw = []; const ws = window.ui && window.ui.ws; if (ws && ws.addEventListener) { ws.addEventListener('message', (e) => { window.__raw.push((e.data||'').toString().slice(0,60)); }); return 'listening'; } return 'no-ws'; })()" 2>&1 | tail -1
CX=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
CY=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 2
echo "after click:"
echo "  path=$(agent-browser eval "location.pathname" 2>&1 | tail -1)"
echo "  raw=$(agent-browser eval "JSON.stringify(window.__raw)" 2>&1 | tail -1)"
echo "  insts=$(agent-browser eval "JSON.stringify({n: window.__insts, sids: window.__instSids})" 2>&1 | tail -1)"