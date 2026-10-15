#!/bin/bash
# UI 评审：逐页截图 + 下拉/弹窗深色实测（隔离实例 18901）
set -u
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm-ui
export AGENT_BROWSER_SESSION=cm-ui-audit
OUT=/home/ystyle/Projects/Cangjie/chronomem-ui/docs/ui/shots/audit
mkdir -p "$OUT"
BASE=${BASE:-http://127.0.0.1:18901}

shot() {  # shot <name>
  agent-browser screenshot --screenshot-dir "$OUT" >/dev/null 2>&1
  local f; f=$(ls -t "$OUT" | grep '^screenshot-' | head -1)
  mv "$OUT/$f" "$OUT/$1.png" 2>/dev/null
  echo "  shot: $1.png"
}

nav() {  # nav <path>
  agent-browser eval "(()=>{location.href='$BASE$1';return 1})()" >/dev/null 2>&1
  sleep 3
}

click_sel() {  # click_sel <index> —— 点开第 index 个 el-select
  local xy
  xy=$(agent-browser eval "(()=>{const s=document.querySelectorAll('.el-select__wrapper, .el-select')[$1]; if(!s) return ''; const r=s.getBoundingClientRect(); return Math.round(r.left+r.width/2)+','+Math.round(r.top+r.height/2);})()" 2>&1 | tail -1 | tr -d '"')
  [ -z "$xy" ] && { echo "  (no select $1)"; return 1; }
  local cx=${xy%,*} cy=${xy#*,}
  agent-browser mouse move "$cx" "$cy" >/dev/null 2>&1
  agent-browser mouse down >/dev/null 2>&1
  agent-browser mouse up >/dev/null 2>&1
  sleep 1
}

echo "=== 逐页截图 ==="
for p in "/:overview" "/tower:tower" "/recall:recall" "/summary:summary" "/types:types" "/append:append"; do
  path=${p%%:*}; name=${p##*:}
  nav "$path"
  shot "$name"
done

echo "=== 下拉深色实测（塔视图类型选择） ==="
nav "/tower"
click_sel 0
# 抓取下拉面板的实际计算样式
agent-browser eval "(()=>{
  const dd=document.querySelector('.el-select-dropdown');
  const pop=document.querySelector('.el-popper');
  const wrap=document.querySelector('.el-select__wrapper');
  const item=document.querySelector('.el-select-dropdown__item');
  const cs=e=>e?getComputedStyle(e):null;
  const g=(e,k)=>e?e.getPropertyValue(k):'n/a';
  const d=cs(dd),p=cs(pop),w=cs(wrap),it=cs(item);
  return JSON.stringify({
    dropdown: !!dd, popper: !!pop,
    dd_bg: g(d,'background-color'), dd_border: g(d,'border-color'), dd_color: g(d,'color'),
    pop_bg: g(p,'background-color'), pop_border: g(p,'border-color'),
    item_color: g(it,'color'),
    wrap_bg: g(w,'background-color'), wrap_border: g(w,'border-color'),
  },null,1);
})()" 2>&1 | tail -20
shot "tower-select-open"

echo "=== 回想页下拉 ==="
nav "/recall"
click_sel 0
agent-browser eval "(()=>{const dd=document.querySelector('.el-select-dropdown');const cs=dd?getComputedStyle(dd):null;return JSON.stringify({open:!!dd,bg:cs?cs.backgroundColor:'n/a',color:cs?cs.color:'n/a'});})()" 2>&1 | tail -2
shot "recall-select-open"

echo "=== 语义总结页下拉 + 单选 ==="
nav "/summary"
click_sel 0
agent-browser eval "(()=>{const dd=document.querySelector('.el-select-dropdown');const cs=dd?getComputedStyle(dd):null;return JSON.stringify({open:!!dd,bg:cs?cs.backgroundColor:'n/a'});})()" 2>&1 | tail -2
shot "summary-select-open"

echo "=== 记忆类型页：创建弹窗（含多选/开关） ==="
nav "/types"
agent-browser eval "(()=>{const b=[...document.querySelectorAll('.ui-btn')].find(x=>x.textContent.includes('创建类型'));if(b){const r=b.getBoundingClientRect();window.__c=[Math.round(r.left+r.width/2),Math.round(r.top+r.height/2)];}return JSON.stringify(window.__c||null);})()" 2>&1 | tail -1
agent-browser eval "(()=>{const b=[...document.querySelectorAll('.ui-btn')].find(x=>x.textContent.includes('创建类型'));b.click();return 1})()" >/dev/null 2>&1
sleep 2
shot "types-create-dialog"
click_sel 0 2>/dev/null
shot "types-dialog-select-open"

echo "=== 追加条目页（textarea + 实时 payload） ==="
nav "/append"
shot "append"

echo done
