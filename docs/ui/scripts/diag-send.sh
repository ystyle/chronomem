#!/bin/bash
# hook send：点击菜单后检查是否有 action 帧发出
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-hook
agent-browser close --all >/dev/null 2>&1
sleep 1
agent-browser open http://127.0.0.1:8901 >/dev/null 2>&1
sleep 4
agent-browser eval "(() => { window.__sent = []; const ui = window.ui; if (!ui) return 'no-ui'; const orig = ui.send.bind(ui); ui.send = (d) => { window.__sent.push(d); return orig(d); }; return 'hooked:' + (ui.ws ? ui.ws.readyState : 'noui-ws'); })()" 2>&1 | tail -1
CX=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2); })()" 2>&1 | tail -1)
CY=$(agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[1]; const r=n.getBoundingClientRect(); return Math.round(r.top+r.height/2); })()" 2>&1 | tail -1)
echo "nav=($CX,$CY)"
agent-browser mouse move $CX $CY >/dev/null 2>&1; agent-browser mouse down >/dev/null 2>&1; agent-browser mouse up >/dev/null 2>&1
sleep 2
echo "sent: $(agent-browser eval "JSON.stringify(window.__sent)" 2>&1 | tail -1)"
echo "path: $(agent-browser eval "location.pathname" 2>&1 | tail -1)"
echo "wsState: $(agent-browser eval "window.ui.ws.readyState" 2>&1 | tail -1)"