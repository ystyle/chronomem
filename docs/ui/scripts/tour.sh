#!/bin/bash
# agent-browser 完整 UI 遍历：逐页真实点击 + 截图 + 状态校验（测试实例 8911）
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm
export AGENT_BROWSER_SESSION=cm-tour
OUT=/home/ystyle/Projects/Cangjie/chronomem/docs/ui/shots/tour
mkdir -p "$OUT"

click_at() {
  agent-browser mouse move "$1" "$2" >/dev/null 2>&1
  agent-browser mouse down >/dev/null 2>&1
  agent-browser mouse up >/dev/null 2>&1
}
nav_center() {
  agent-browser eval "(() => { const n=document.querySelectorAll('.ui-nav')[$1]; const r=n.getBoundingClientRect(); return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2); })()" 2>&1 | tail -1 | tr -d '"'
}

agent-browser close --all >/dev/null 2>&1; sleep 1
agent-browser open http://127.0.0.1:8921 >/dev/null 2>&1
sleep 4

PAGES=(总览 塔视图 回想 语义总结 记忆类型 追加条目)
for i in 0 1 2 3 4 5; do
  NC=$(nav_center "$i")
  CX=$(echo "$NC" | cut -d' ' -f1); CY=$(echo "$NC" | cut -d' ' -f2)
  click_at "$CX" "$CY"
  sleep 3
  PATHNOW=$(agent-browser eval "location.pathname" 2>&1 | tail -1 | tr -d '"')
  echo "page$i [${PAGES[$i]}] path=$PATHNOW"
  agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1
  # 记住截图最新文件名
  ls -t "$OUT" | head -1 > "$OUT/last-$i.txt"
done
echo done