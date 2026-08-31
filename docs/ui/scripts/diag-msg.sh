#!/bin/bash
# hook handleMsg：记录服务端下发的所有消息 kind/path
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-msg
agent-browser close --all >/dev/null 2>&1
sleep 1
agent-browser open http://127.0.0.1:8901 >/dev/null 2>&1
sleep 4
agent-browser eval "(() => { window.__msgs = []; const ui = window.ui; if (!ui) return 'no-ui'; const orig = ui.handleMsg.bind(ui); ui.handleMsg = (m) => { window.__msgs.push({k: m.kind, path: m.path || null, trees: m.trees ? m.trees.length : (m.tree ? 1 : 0)}); return orig(m); }; return 'ok'; })()" 2>&1 | tail -1
CX=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
CY=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 2
echo "path=$(agent-browser eval "location.pathname" 2>&1 | tail -1)"
echo "msgs=$(agent-browser eval "JSON.stringify(window.__msgs)" 2>&1 | tail -1)"
echo "dom=$(agent-browser eval "JSON.stringify({appKids: document.getElementById('app').children.length, buckets: document.querySelectorAll('.ui-bucket').length})" 2>&1 | tail -1)"