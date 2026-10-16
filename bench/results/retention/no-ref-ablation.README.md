# 无引用号消融（回应"exact 是否因 token 而过于容易"）

## 问题

评审指出：合成 trace 在事实文本里嵌了不透明引用号（`(ref ZR01)`），而摘要会逐字复制它，
可能让 exact 下钻变成 **trivially extractable**，从而高估无 LLM 路径的优势。

## 设计

两份 trace **只差 token 一项**：同 seed、同 390 事件、同 32 探针、同主题/答案/滞后安排。
无 token 版把探针改为按 `(topic, day)` 提问，由读取器靠**天号消歧**。

可逐字节复现（已用 `cmp` 验证），故不存 trace 文件，只存生成命令：

```shell
python3 gen_trace.py --days 30 --agents 3 --seed 7 --facts-per-day 3 --filler-per-day 7 \
  --out trace-ref.json
python3 gen_trace.py --days 30 --agents 3 --seed 7 --facts-per-day 3 --filler-per-day 7 --no-ref \
  --out trace-noref.json
```

## 结果

| 臂 | 带 ref | 无 ref |
|---|---|---|
| flat-recency | 0.0% | 0.0% |
| compaction（破坏性） | 0.0% | 0.0% |
| compaction（保守） | 100.0% | 100.0% |
| **chronomem-exact** | **100.0%** | **100.0%** |

摘要臂（10 天小 trace，12 探针）：带 ref 25.0% / 无 ref 25.0%。

## 结论

**评审的担心在准确率层面不成立**：去掉 token 后 exact 仍是 100%。原因是 exact 下钻读的是
**原始条目**，那里本来就带 `[topic]` 与 `day N`，token 从来不是那条路径的承重件。
已验证 `vun` 在一次探针的证据里出现两次（day 2 = A、day 3 = B），读取器正确地按天选了 A。

**但同一实验也否定了我们自己的预期**：原以为 token 对**摘要臂**重要。实测两者都是 25%。
机制是：摘要是按章节组织的（决策／结论／待办），topic 在决策段、天号在标题与结论段，
而读取器的严格模式要求 **topic 与天号同段**——带不带 token 都一样失败。token 没救回来，
因为它与天号同样分处不同段。

**更诚实的读法**：这份 trace 无法把 token 的作用与读取器的结构性局限分开。
更干净的消融应当**变读取器**而不是变 token——这已写进论文的 future work。
