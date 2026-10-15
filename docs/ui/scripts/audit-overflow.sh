#!/bin/bash
# 溢出自检：检测「内容被裁切」的元素（客户点名的「看不全」问题）
# 每页单独 open（open 后 location.href 赋值会被 agent-browser 会话重置，故用 open 直达）
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm-ui
export AGENT_BROWSER_SESSION=cm-ui-overflow
BASE=http://127.0.0.1:18901

probe() {  # probe <path> <label>
  agent-browser open "$BASE$1" >/dev/null 2>&1
  sleep 4
  local path; path=$(agent-browser eval "location.pathname" 2>&1 | tail -1)
  local n; n=$(agent-browser eval "document.querySelectorAll('*').length" 2>&1 | tail -1)
  echo "### $2  $1  (path=$path nodes=$n)"
  agent-browser eval "(()=>{
    const out=[];
    document.querySelectorAll('*').forEach(e=>{
      const s=getComputedStyle(e);
      const cy=e.scrollHeight>e.clientHeight+2 && /hidden|clip/.test(s.overflowY);
      const cx=e.scrollWidth>e.clientWidth+2 && /hidden|clip/.test(s.overflowX);
      if ((cy||cx) && e.clientHeight>0) {
        out.push({c:(e.className||e.tagName).toString().slice(0,46),
                  o:(e.scrollHeight-e.clientHeight)+'x'+(e.scrollWidth-e.clientWidth),
                  m:s.maxHeight, t:(e.textContent||'').trim().slice(0,36)});
      }
    });
    return JSON.stringify(out.slice(0,12));
  })()" 2>&1 | tail -1 | python3 -c '
import sys,json
raw=sys.stdin.read().strip()
try:
    d=json.loads(json.loads(raw))
except Exception:
    print("   (no clip found)"); raise SystemExit
if not d: print("   (no clip found)")
for x in d:
    print("   - %-44s dyx=%-9s maxH=%-8s | %s" % (x["c"],x["o"],x["m"],x["t"]))
'
}

probe "/" "总览"
probe "/tower" "塔视图"
probe "/recall" "回想"
probe "/summary" "语义总结"
probe "/types" "记忆类型"
probe "/append" "追加条目"
