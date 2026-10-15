#!/bin/bash
# 下拉深色根因实测：打开下拉后，逐层打印 CSS 变量与最终生效值
export AGENT_BROWSER_SOCKET_DIR=/tmp/ab-cm-ui
export AGENT_BROWSER_SESSION=cm-ui-diag
BASE=http://127.0.0.1:18901

agent-browser close --all >/dev/null 2>&1; sleep 1
agent-browser open "$BASE/tower" >/dev/null 2>&1; sleep 5

# 用 JS 直接触发选择器展开（不依赖鼠标坐标）
agent-browser eval "(()=>{const w=document.querySelector('.el-select__wrapper')||document.querySelector('.el-select');if(!w)return 'no-select';w.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}));w.click();return 'clicked';})()" 2>&1 | tail -1
sleep 2

agent-browser eval "(()=>{
  const dd=document.querySelector('.el-select-dropdown');
  if(!dd) return 'NOT-OPEN';
  const cs=getComputedStyle(dd);
  const chain=[];
  let e=dd;
  while(e && e!==document.documentElement.parentElement){
    const s=getComputedStyle(e);
    chain.push({
      tag:e.tagName+(e.className?('.'+String(e.className).split(' ').slice(0,2).join('.')):''),
      bg:s.backgroundColor,
      color:s.color,
      overlay:s.getPropertyValue('--el-bg-color-overlay').trim(),
      bgvar:s.getPropertyValue('--el-bg-color').trim(),
    });
    e=e.parentElement;
  }
  return JSON.stringify({dd_bg:cs.backgroundColor, dd_color:cs.color, chain},null,1);
})()" 2>&1 | tail -60
