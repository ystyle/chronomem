import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  DISTILL_SYSTEM,
  KIND,
  TYPE_ACTIVITY,
  TYPE_CHAT,
  appendRequest,
  blockKinds,
  buildDistillPrompt,
  callRequest,
  clipText,
  closeEntry,
  compactEntry,
  compactTags,
  errorEntry,
  firstLine,
  goalEntry,
  DEFAULT_WORKSPACE_LEVEL,
  TOOL_MODES,
  formatWorkspaceList,
  isFullContextWorkspace,
  isRetryableWriteFailure,
  isTypeExistsFailure,
  isSubstantiveTurn,
  lifecycleEntry,
  mcpHeaders,
  mcpUrl,
  milestoneEntry,
  parseDistillReply,
  parseMcpBody,
  parseWorkspaceList,
  parseWorkspaceListStrict,
  projFromCwd,
  resolveConfig,
  resultText,
  rpcFailure,
  sayEntry,
  textOfBlocks,
  titleEntry,
  typeCreateArgs,
  typeReviveArgs,
  typeSpecs,
  toolEntry,
  turnEntry,
  userEntry,
  userTextOf,
  workflowEntry,
  workspaceLevelFor,
  workspaceRuleFor,
} from '../lib/pure.js'

const subject = { session: 'session-1', agent: 'session-1', proj: 'Cangjie' }

test('clipText leaves short text untouched', () => {
  assert.equal(clipText('hello', 10), 'hello')
  assert.equal(clipText('hello', 5), 'hello')
})

test('clipText keeps both ends and reports the omission', () => {
  const text = 'a'.repeat(60) + 'b'.repeat(40)
  const clipped = clipText(text, 20)
  assert.ok(clipped.startsWith('a'.repeat(12)), 'keeps head')
  assert.ok(clipped.endsWith('b'.repeat(8)), 'keeps tail')
  assert.match(clipped, /省略 80 字/)
})

test('clipText treats a non-positive max as no limit, and non-strings as empty', () => {
  assert.equal(clipText('x'.repeat(50), 0), 'x'.repeat(50))
  assert.equal(clipText(undefined, 10), '')
  assert.equal(clipText(null, 10), '')
})

test('firstLine takes the first line only, then clips', () => {
  assert.equal(firstLine('first\nsecond\nthird', 100), 'first')
  assert.equal(firstLine('  padded  \nrest', 100), 'padded')
  // 标题只截尾，不插「省略」标记（首尾截断留给 note）
  assert.equal(firstLine('x'.repeat(50), 10), 'x'.repeat(10) + '…')
  assert.equal(firstLine('y'.repeat(10), 10), 'y'.repeat(10))
})

test('textOfBlocks keeps text blocks only', () => {
  const blocks = [
    { type: 'reasoning', text: 'scratch' },
    { type: 'text', text: 'answer one' },
    { type: 'tool-call', name: 'bash' },
    { type: 'text', text: 'answer two' },
  ]
  assert.equal(textOfBlocks(blocks), 'answer one\nanswer two')
  assert.deepEqual(blockKinds(blocks), ['reasoning', 'text', 'tool-call', 'text'])
  assert.equal(textOfBlocks(undefined), '')
  assert.deepEqual(blockKinds('nope'), [])
})

test('projFromCwd falls back to the directory name', () => {
  assert.equal(projFromCwd('/home/ystyle/Projects/Cangjie', {}), 'Cangjie')
  assert.equal(projFromCwd('/home/ystyle/Projects/chronomem/', {}), 'chronomem')
  assert.equal(projFromCwd('relative', {}), 'relative')
  assert.equal(projFromCwd('', {}), null)
  assert.equal(projFromCwd(undefined, {}), null)
  assert.equal(projFromCwd('/', {}), null)
})

test('projFromCwd prefers the longest matching mapping prefix', () => {
  const map = {
    '/home/ystyle/Projects/Cangjie': 'Cangjie',
    '/home/ystyle/Projects/Cangjie/chronomem': 'chronomem',
  }
  assert.equal(projFromCwd('/home/ystyle/Projects/Cangjie/chronomem/src', map), 'chronomem')
  assert.equal(projFromCwd('/home/ystyle/Projects/Cangjie/other', map), 'Cangjie')
  // Prefix must land on a path boundary, not a bare string prefix.
  assert.equal(projFromCwd('/home/ystyle/Projects/Cangjie-extra', map), 'Cangjie-extra')
  // Mapping value wins over the directory-name fallback.
  assert.equal(projFromCwd('/home/ystyle/Projects/Cangjie', { '/home/ystyle/Projects/Cangjie': 'MyProduct' }), 'MyProduct')
})

test('compactTags drops null, undefined and empty values', () => {
  assert.deepEqual(compactTags({ a: 'x', b: null, c: undefined, d: '', e: 0, f: false }), {
    a: 'x',
    e: '0',
    f: 'false',
  })
})

test('lifecycleEntry distinguishes open from resume', () => {
  assert.equal(lifecycleEntry(subject, 'startup').tags.kind, KIND.open)
  assert.equal(lifecycleEntry(subject, 'clear').tags.kind, KIND.open)
  assert.equal(lifecycleEntry(subject, 'resume').tags.kind, KIND.resume)
  assert.equal(lifecycleEntry(subject, 'compact').tags.kind, KIND.open)
  assert.match(lifecycleEntry(subject, 'resume').payload.note, /source=resume/)
})

test('titleEntry records the durable session title', () => {
  const e = titleEntry(subject, '检查忆时塔会话记忆计划', 'provider')
  assert.equal(e.tags.kind, KIND.title)
  assert.equal(e.payload.title, '检查忆时塔会话记忆计划')
  assert.equal(e.payload.note, 'source=provider')
})

test('turnEntry carries the clipped final answer plus stats', () => {
  const text = '结论：可以开始\n' + 'y'.repeat(9000)
  const e = turnEntry(subject, { turn: 3, text, toolCalls: 39, toolErrors: 0, noteMax: 6000 })
  assert.equal(e.tags.kind, KIND.turn)
  assert.equal(e.tags.turn, '3')
  assert.equal(e.tags.session, 'session-1')
  assert.equal(e.tags.proj, 'Cangjie')
  assert.equal(e.payload.title, '结论：可以开始')
  assert.ok(e.payload.note.length < 6100, 'note is clipped near noteMax')
  assert.match(e.payload.note, /省略/)
  assert.equal(e.payload.stats, 'tools=39')
  assert.equal(turnEntry(subject, { turn: 1, text: 'x', toolCalls: 2, toolErrors: 1, noteMax: 100 }).payload.stats, 'tools=2 errors=1')
})

test('compactEntry captures span, id and the pre-distilled summary', () => {
  const e = compactEntry(subject, {
    compactionId: 'cid-9',
    summaryText: '早期历史要点',
    shadowedRange: { start: 123, end: 456 },
    shadowedTokenCount: 12345,
  })
  assert.equal(e.tags.kind, KIND.compact)
  assert.equal(e.tags.span, '123..456')
  assert.equal(e.tags.cid, 'cid-9')
  assert.equal(e.payload.title, '上下文压缩 span 123..456')
  assert.equal(e.payload.note, '早期历史要点')
  assert.equal(e.payload.stats, 'shadowedTokenCount=12345')
})

test('compactEntry tolerates a missing span', () => {
  const e = compactEntry(subject, { compactionId: 'cid', summaryText: 's' })
  assert.equal(e.tags.span, undefined)
  assert.equal(e.payload.title, '上下文压缩')
})

test('goalEntry mirrors the goal state machine', () => {
  const e = goalEntry(subject, {
    goalId: 'g-1',
    revision: 7,
    phase: 'blocked',
    operation: 'block',
    objective: '搭好桥',
    progress: '写完纯逻辑',
    blocker: 'AUTH_MISSING',
    noteMax: 2000,
  })
  assert.equal(e.tags.kind, KIND.goal)
  assert.equal(e.tags.goal, 'g-1')
  assert.equal(e.tags.rev, '7')
  assert.equal(e.tags.phase, 'blocked')
  assert.equal(e.payload.title, '搭好桥')
  assert.equal(e.payload.blocker, 'AUTH_MISSING')
  assert.equal(e.payload.progress, '写完纯逻辑')
  assert.match(e.payload.note, /operation=block/)
})

test('goalEntry omits absent progress and blocker', () => {
  const e = goalEntry(subject, { goalId: 'g', revision: 1, phase: 'active', operation: 'create', objective: 'o' })
  assert.equal(e.payload.progress, undefined)
  assert.equal(e.payload.blocker, undefined)
})

test('milestoneEntry records a subagent result', () => {
  const e = milestoneEntry(subject, { runId: 'run-1', stopReason: 'completed', text: '干完了', noteMax: 2000 })
  assert.equal(e.tags.kind, KIND.milestone)
  assert.equal(e.tags.run, 'run-1')
  assert.equal(e.payload.outcome, 'completed')
  assert.match(e.payload.title, /completed/)
  assert.equal(e.payload.note, '干完了')
})

test('errorEntry stores the code, never the body', () => {
  const e = errorEntry(subject, { turn: 4, step: 2, code: 'LLM_TIMEOUT' })
  assert.equal(e.tags.kind, KIND.error)
  assert.equal(e.tags.turn, '4')
  assert.equal(e.tags.step, '2')
  assert.equal(e.payload.blocker, 'LLM_TIMEOUT')
  assert.equal(e.payload.note, 'code=LLM_TIMEOUT')
})

test('closeEntry is the L2b aggregate account', () => {
  const e = closeEntry(subject, { goalId: 'g-1', objective: '搭好桥', outcome: '3 个提交', next: '装包', note: '收口叙述', distilled: true })
  assert.equal(e.tags.kind, KIND.close)
  assert.equal(e.tags.goal, 'g-1')
  assert.equal(e.tags.distilled, 'true')
  assert.equal(e.payload.title, '搭好桥')
  assert.equal(e.payload.outcome, '3 个提交')
  assert.equal(e.payload.next, '装包')
  // 骨架退化的形态：无 objective / 未蒸馏
  const skeleton = closeEntry(subject, { goalId: 'g-2', note: '骨架收口（未蒸馏）' })
  assert.equal(skeleton.tags.distilled, 'false')
  assert.equal(skeleton.payload.title, '目标收口')
})

test('workflowEntry records workflow facts, not a fabricated result', () => {
  const e = workflowEntry({ session: null, agent: null, proj: null },
    { runId: 'wf-1', name: 'audit-fanout', description: '并行审计', stopReason: 'completed', agentsStarted: 7 })
  assert.equal(e.tags.kind, KIND.milestone)
  assert.equal(e.tags.role, 'workflow')
  assert.equal(e.tags.run, 'wf-1')
  assert.equal(e.tags.session, undefined, 'workflow 没有 session，不应编造')
  assert.equal(e.payload.title, '工作流结束（audit-fanout）')
  assert.match(e.payload.note, /stopReason=completed/)
  assert.match(e.payload.note, /agentsStarted=7/)
  assert.match(e.payload.note, /并行审计/)
  assert.equal(e.payload.outcome, 'completed')
  // 失败路径带 error 事实
  const failed = workflowEntry({}, { runId: 'wf-2', stopReason: 'error', agentsStarted: 0, error: 'boom' })
  assert.match(failed.payload.note, /error=boom/)
})

test('buildDistillPrompt carries the goal plus the tower timeline', () => {
  const prompt = buildDistillPrompt({ goalId: 'g-1', objective: '搭好桥', timeline: '[t] {"note":"x"} <kind=turn>' })
  assert.match(prompt, /goalId: g-1/)
  assert.match(prompt, /objective: 搭好桥/)
  assert.match(prompt, /kind=turn/)
  assert.match(prompt, /只输出约定的 JSON/)
  // 空时间线不应崩，且明确标注无条目
  assert.match(buildDistillPrompt({ goalId: '', objective: '', timeline: '   ' }), /\(无条目\)/)
  assert.match(DISTILL_SYSTEM, /JSON/)
})

test('parseDistillReply accepts JSON, prose-wrapped JSON, and degrades to plain text', () => {
  assert.deepEqual(parseDistillReply('{"outcome":"o","next":"n","note":"x"}'), { outcome: 'o', next: 'n', note: 'x' })
  // 小模型常把 JSON 包在说明文字或代码块里 —— 取首个 { 到末个 }
  assert.deepEqual(
    parseDistillReply('好的：\n```json\n{"outcome":"o","next":"","note":"x"}\n```\n以上。'),
    { outcome: 'o', next: '', note: 'x' },
  )
  // 只有部分字段也可用
  assert.deepEqual(parseDistillReply('{"note":"只有叙述"}'), { outcome: '', next: '', note: '只有叙述' })
  // 完全无法解析 → 整段作为 note，而不是丢弃（这是花过 LLM 钱的产出）
  assert.deepEqual(parseDistillReply('就是一段中文总结'), { outcome: '', next: '', note: '就是一段中文总结' })
  // 全空字段视为解析失败 → 同样退化为纯文本
  assert.deepEqual(parseDistillReply('{"outcome":"","next":"","note":""}'), { outcome: '', next: '', note: '{"outcome":"","next":"","note":""}' })
  assert.deepEqual(parseDistillReply(''), { outcome: '', next: '', note: '' })
  assert.deepEqual(parseDistillReply(undefined), { outcome: '', next: '', note: '' })
})

test('entry tags never carry an empty proj/session', () => {
  const e = turnEntry({ session: '', agent: 'a', proj: null }, { turn: 1, text: 'x', toolCalls: 1, noteMax: 10 })
  assert.equal(e.tags.session, undefined)
  assert.equal(e.tags.proj, undefined)
  assert.equal(e.tags.agent, 'a')
})

test('resolveConfig applies defaults', () => {
  const c = resolveConfig({}, {})
  assert.equal(c.url, 'http://127.0.0.1:8900')
  assert.equal(c.type, TYPE_ACTIVITY)
  assert.equal(c.token, '')
  assert.equal(c.enabled, true)
  assert.equal(c.queueMax, 500)
  assert.equal(c.retryMax, 5)
  assert.equal(c.retryBackoffMs, 250)
  assert.equal(c.distill, true)
  assert.equal(c.distillProvider, '')
  assert.equal(c.distillModel, '')
  assert.equal(c.tailN, 20)
  assert.equal(c.maxDaily, 20)
  assert.equal(c.turnNoteMax, 6000)
  assert.equal(c.compactNoteMax, 16000)
  assert.equal(c.turnMinTools, 1)
  assert.equal(c.turnMinLen, 120)
  assert.deepEqual(c.projMap, {})
})

test('resolveConfig lets env override defaults and row config override env', () => {
  const env = {
    DSH_MEM_BRIDGE_URL: 'http://env:8900',
    DSH_MEM_BRIDGE_TOKEN: 'env-token',
    DSH_MEM_BRIDGE_ENABLE: 'false',
    DSH_MEM_BRIDGE_TURN_NOTE_MAX: '1234',
  }
  const fromEnv = resolveConfig({}, env)
  assert.equal(fromEnv.url, 'http://env:8900')
  assert.equal(fromEnv.token, 'env-token')
  assert.equal(fromEnv.enabled, false)
  assert.equal(fromEnv.turnNoteMax, 1234)

  const fromRow = resolveConfig({ url: 'http://row:8900', enabled: true, projMap: { '/x': 'X' } }, env)
  assert.equal(fromRow.url, 'http://row:8900')
  assert.equal(fromRow.enabled, true)
  assert.equal(fromRow.token, 'env-token', 'unspecified row fields still fall back to env')
  assert.deepEqual(fromRow.projMap, { '/x': 'X' })
})

test('isSubstantiveTurn uses OR semantics', () => {
  const policy = { turnMinTools: 1, turnMinLen: 120 }
  assert.equal(isSubstantiveTurn({ toolCalls: 3, text: '' }, policy), true, 'work done')
  assert.equal(isSubstantiveTurn({ toolCalls: 0, text: 'x'.repeat(200) }, policy), true, 'pure discussion')
  assert.equal(isSubstantiveTurn({ toolCalls: 0, text: 'thanks' }, policy), false, 'bare acknowledgement')
  assert.equal(isSubstantiveTurn({ toolCalls: 0, text: '' }, policy), false)
})

test('isSubstantiveTurn records everything when both thresholds are disabled', () => {
  const policy = { turnMinTools: 0, turnMinLen: 0 }
  assert.equal(isSubstantiveTurn({ toolCalls: 0, text: 'hi' }, policy), true)
})

test('appendRequest builds one mem/append tools/call', () => {
  const e = turnEntry(subject, { turn: 2, text: 'done', toolCalls: 1, noteMax: 100 })
  const req = appendRequest(7, TYPE_ACTIVITY, e, 1704110400000)
  assert.equal(req.jsonrpc, '2.0')
  assert.equal(req.id, 7)
  assert.equal(req.method, 'tools/call')
  assert.equal(req.params.name, 'mem/append')
  assert.equal(req.params.arguments.type, 'dsh/activity')
  assert.equal(req.params.arguments.ts, 1704110400000)
  assert.equal(req.params.arguments.tags.kind, 'turn')
  assert.equal(req.params.arguments.payload.note, 'done')

  // No ts => the tower stamps it.
  assert.equal(appendRequest(1, TYPE_ACTIVITY, e).params.arguments.ts, undefined)
})

test('callRequest targets any read-only tool', () => {
  const req = callRequest(9, 'mem/list_types', {})
  assert.equal(req.params.name, 'mem/list_types')
  assert.deepEqual(req.params.arguments, {})
  assert.deepEqual(callRequest(9, 'x', null).params.arguments, {})
})

test('mcpUrl normalises the base and mcpHeaders adds the token only when set', () => {
  assert.equal(mcpUrl('http://127.0.0.1:8900'), 'http://127.0.0.1:8900/mcp')
  assert.equal(mcpUrl('http://127.0.0.1:8900///'), 'http://127.0.0.1:8900/mcp')
  assert.equal(mcpUrl(''), 'http://127.0.0.1:8900/mcp')
  assert.equal(mcpHeaders('').authorization, undefined)
  assert.equal(mcpHeaders('k').authorization, 'Bearer k')
  assert.equal(mcpHeaders('k').accept, 'application/json, text/event-stream')
})

test('parseMcpBody reads a plain JSON response', () => {
  const body = parseMcpBody('{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"ok"}]}}')
  assert.equal(body.id, 1)
  assert.equal(resultText(body.result), 'ok')
})

test('parseMcpBody reads an SSE frame stream and keeps the last complete frame', () => {
  const sse = [
    'event: message',
    'data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"first"}]}}',
    '',
    'event: message',
    'data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"second"}]}}',
    '',
  ].join('\n')
  const body = parseMcpBody(sse)
  assert.equal(resultText(body.result), 'second')
})

test('parseMcpBody survives partial frames, empty bodies and non-strings', () => {
  assert.equal(parseMcpBody(''), null)
  assert.equal(parseMcpBody('   '), null)
  assert.equal(parseMcpBody(undefined), null)
  assert.equal(parseMcpBody('not json at all'), null)
  assert.equal(parseMcpBody('data: {"broken"'), null)
  assert.equal(parseMcpBody('data: [DONE]'), null)
  // A trailing broken frame must not discard the last complete one.
  const partial = parseMcpBody('data: {"a":1}\ndata: not-json')
  assert.equal(partial.a, 1)
})

test('rpcFailure reports JSON-RPC errors, tool errors and success', () => {
  assert.equal(rpcFailure({ jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: 'ok' }] } }), null)
  assert.equal(
    rpcFailure({ jsonrpc: '2.0', id: 1, error: { code: -32601, message: 'Method not found' } }),
    'JSON-RPC error -32601: Method not found',
  )
  assert.equal(
    rpcFailure({ jsonrpc: '2.0', id: 1, result: { isError: true, content: [{ type: 'text', text: '类型不存在: t' }] } }),
    'tool error: 类型不存在: t',
  )
  assert.equal(rpcFailure(null), 'empty response body')
  assert.equal(rpcFailure(undefined), 'empty response body')
  assert.equal(rpcFailure('nope'), 'unexpected response shape')
})

test('isRetryableWriteFailure retries only provably-undelivered requests', () => {
  // Connect-level failures: the request never reached the tower.
  for (const code of ['ECONNREFUSED', 'EHOSTUNREACH', 'ENETUNREACH', 'ENOTFOUND', 'EAI_AGAIN']) {
    const error = new TypeError('fetch failed')
    error.cause = { code }
    assert.equal(isRetryableWriteFailure(error), true, `${code} should retry`)
    assert.equal(isRetryableWriteFailure(new Error(`connect ${code} 127.0.0.1:8900`)), true, `${code} in message should retry`)
  }

  // Ambiguous outcomes: the tower may have applied the append already.
  const aborted = new Error('This operation was aborted')
  aborted.name = 'AbortError'
  assert.equal(isRetryableWriteFailure(aborted), false)

  const timeout = new Error('timed out')
  timeout.name = 'TimeoutError'
  assert.equal(isRetryableWriteFailure(timeout), false)

  // A mid-flight reset is ambiguous too — never repeat it.
  const reset = new TypeError('fetch failed')
  reset.cause = { code: 'ECONNRESET' }
  assert.equal(isRetryableWriteFailure(reset), false)

  // Application-level failures will not become successes by repeating them.
  assert.equal(isRetryableWriteFailure(new Error('HTTP 500 Internal Server Error')), false)
  assert.equal(isRetryableWriteFailure(new Error('tool error: 类型不存在: t')), false)
  assert.equal(isRetryableWriteFailure(null), false)
  assert.equal(isRetryableWriteFailure('boom'), false)
})

// ---------------------------------------------------------------------------
// Full-context workspaces (feat/full-context-mode)
//
// A full-context workspace records the whole exchange — what the human typed,
// every assistant message, and (per `fullContextTools`) the tool traffic. The
// default profile keeps none of that, so every function below has to be a no-op
// on an empty list; that is asserted first in each case.
// ---------------------------------------------------------------------------

test('parseWorkspaceList reads 路径 = 级别 lines into rows', () => {
  assert.deepEqual(parseWorkspaceList(''), [])
  assert.deepEqual(parseWorkspaceList(null), [])
  assert.deepEqual(parseWorkspaceList('   '), [])

  const text = [
    '  /home/me/notes = none  ',
    '',
    '# a comment line is ignored',
    'journal',
    '/home/me/notes = full', // duplicate path: the first line wins
    '   journal   ', // duplicate of the bare name
    '/home/me/work/ = full',
  ].join('\n')
  assert.deepEqual(parseWorkspaceList(text), [
    { path: '/home/me/notes', level: 'none' },
    { path: 'journal', level: 'names' },
    { path: '/home/me/work', level: 'full' },
  ])
})

test('parseWorkspaceList defaults a missing level to names', () => {
  assert.deepEqual(parseWorkspaceList('/a'), [{ path: '/a', level: DEFAULT_WORKSPACE_LEVEL }])
  assert.deepEqual(parseWorkspaceList('/a =   '), [{ path: '/a', level: 'names' }])
})

test('parseWorkspaceList tolerates a path containing spaces', () => {
  assert.deepEqual(parseWorkspaceList('/home/me/my notes = full'), [{ path: '/home/me/my notes', level: 'full' }])
})

test('parseWorkspaceListStrict reports an unknown level so the save is blocked', () => {
  assert.equal(parseWorkspaceListStrict('/a = bogus'), undefined)
  assert.equal(parseWorkspaceListStrict('/a = none\n/b = bogus'), undefined)
  // The tolerant variant still keeps the workspace, at the default level.
  assert.deepEqual(parseWorkspaceList('/a = bogus'), [{ path: '/a', level: 'names' }])
})

test('parseWorkspaceList accepts an already-structured array', () => {
  assert.deepEqual(
    parseWorkspaceList([{ path: '/a', level: 'full' }, { path: '/b' }, { path: '/a', level: 'none' }]),
    [{ path: '/a', level: 'full' }, { path: '/b', level: 'names' }],
  )
  assert.deepEqual(parseWorkspaceList([]), [])
  assert.deepEqual(parseWorkspaceList([null, 3, 'x']), [])
})

test('formatWorkspaceList round-trips through parseWorkspaceList', () => {
  const rows = [{ path: '/a', level: 'full' }, { path: 'journal', level: 'none' }]
  assert.equal(formatWorkspaceList(rows), '/a = full\njournal = none')
  assert.deepEqual(parseWorkspaceList(formatWorkspaceList(rows)), rows)
  assert.equal(formatWorkspaceList(null), '')
  // A bad level renders as the default rather than as a lie.
  assert.equal(formatWorkspaceList([{ path: '/a', level: 'bogus' }]), '/a = names')
})

test('workspaceRuleFor is null for an empty list (the default profile)', () => {
  for (const workspaces of [[], undefined, null]) {
    assert.equal(workspaceRuleFor('/home/ystyle/notes', workspaces), null)
  }
  assert.equal(workspaceRuleFor('', [{ path: '/home/ystyle/notes', level: 'full' }]), null)
  assert.equal(workspaceRuleFor(null, [{ path: '/home/ystyle/notes', level: 'full' }]), null)
})

test('workspaceRuleFor matches an absolute entry as a path prefix on a segment boundary', () => {
  const workspaces = [{ path: '/home/ystyle/notes', level: 'full' }]
  assert.equal(workspaceRuleFor('/home/ystyle/notes', workspaces).level, 'full')
  assert.equal(workspaceRuleFor('/home/ystyle/notes/', workspaces).level, 'full')
  assert.equal(workspaceRuleFor('/home/ystyle/notes/2026', workspaces).level, 'full')
  // The segment boundary is what keeps a sibling directory out.
  assert.equal(workspaceRuleFor('/home/ystyle/notes-old', workspaces), null)
  assert.equal(workspaceRuleFor('/home/ystyle/other', workspaces), null)
})

test('workspaceRuleFor matches a bare entry against the last path segment only', () => {
  const workspaces = [{ path: 'notes', level: 'none' }]
  assert.equal(workspaceRuleFor('/home/ystyle/notes', workspaces).level, 'none')
  assert.equal(workspaceRuleFor('/tmp/elsewhere/notes/', workspaces).level, 'none')
  assert.equal(workspaceRuleFor('/home/ystyle/notes/deeper', workspaces), null)
  assert.equal(workspaceRuleFor('/home/ystyle/notes2', workspaces), null)
})

test('workspaceRuleFor lets a narrow entry beat a broad one', () => {
  // A broad chat workspace with one code subdirectory carved out of it: the
  // longest matching path has to win, or the carve-out would never apply.
  const workspaces = parseWorkspaceList('/home/me/notes = none\n/home/me/notes/code = full')
  assert.equal(workspaceRuleFor('/home/me/notes/2026', workspaces).level, 'none')
  assert.equal(workspaceRuleFor('/home/me/notes/code', workspaces).level, 'full')
  assert.equal(workspaceRuleFor('/home/me/notes/code/src', workspaces).level, 'full')
})

test('workspaceLevelFor distinguishes "not configured" from "none"', () => {
  const cfg = resolveConfig({ fullContextWorkspaces: '/home/me/notes = none' }, {})
  // null means the default profile — every caller then behaves as before.
  assert.equal(workspaceLevelFor('/home/me/work', cfg), null)
  // 'none' is a real answer: the transcript is recorded, the tools are not.
  assert.equal(workspaceLevelFor('/home/me/notes', cfg), 'none')
})

test('userTextOf records only what a human typed', () => {
  const typed = { content: [{ type: 'text', text: '你好' }], source: { kind: 'user' } }
  assert.equal(userTextOf(typed, 'append'), '你好')

  // Injected user-role messages: measured at 17x the size of the human text in
  // one real session, so none of these may reach the tower.
  for (const kind of ['runtime-context', 'skill-catalog', 'time-context', 'tool-jobs', 'compact-checkpoint', 'model-selection', 'system']) {
    const injected = { content: [{ type: 'text', text: 'x'.repeat(500) }], source: { kind } }
    assert.equal(userTextOf(injected, 'append'), '', `${kind} must not be recorded`)
  }
})

test('userTextOf refuses a compaction replacement copy', () => {
  const checkpoint = { content: [{ type: 'text', text: 'compaction checkpoint' }], source: { kind: 'user' } }
  // Compaction re-adds a user message with a replace marker to shadow the range
  // it summarised. That is not a new thing anyone said.
  assert.equal(userTextOf(checkpoint, { op: 'replace', startSeq: 1, endSeq: 9 }), '')
  assert.equal(userTextOf(checkpoint, undefined), '')
  assert.equal(userTextOf(checkpoint, 'append'), 'compaction checkpoint')
})

test('userTextOf tolerates a malformed event', () => {
  assert.equal(userTextOf(null, 'append'), '')
  assert.equal(userTextOf(undefined, 'append'), '')
  assert.equal(userTextOf({}, 'append'), '')
  assert.equal(userTextOf({ content: [], source: { kind: 'user' } }, 'append'), '')
})

test('userEntry clips the text and tags the turn', () => {
  const entry = userEntry(subject, { turn: 3, text: '帮我看看这个配置', noteMax: 6000 })
  assert.equal(entry.payload.title, '帮我看看这个配置')
  assert.equal(entry.payload.note, '帮我看看这个配置')
  assert.equal(entry.tags.kind, 'user')
  assert.equal(entry.tags.turn, '3')
  assert.equal(entry.tags.session, 'session-1')
  assert.equal(entry.tags.proj, 'Cangjie')

  const long = userEntry(subject, { turn: 1, text: 'x'.repeat(50), noteMax: 10 })
  assert.ok(long.payload.note.includes('省略 40 字'))
})

test('sayEntry keeps the step so the exchange stays ordered', () => {
  const entry = sayEntry(subject, { turn: 2, step: 7, text: '我看看。', noteMax: 100 })
  assert.equal(entry.payload.note, '我看看。')
  assert.equal(entry.tags.kind, 'say')
  assert.equal(entry.tags.turn, '2')
  assert.equal(entry.tags.step, '7')
})

test('toolEntry records nothing in mode none', () => {
  assert.equal(toolEntry(subject, { turn: 1, step: 1, callId: 'c1', name: 'bash', mode: 'none', noteMax: 100 }), null)
})

test('toolEntry names mode drops arguments and result but keeps the name', () => {
  const entry = toolEntry(subject, {
    turn: 1,
    step: 2,
    callId: 'call-1',
    name: 'bash',
    args: { command: 'rm -rf /tmp/x' },
    result: 'x'.repeat(5000),
    isError: false,
    mode: 'names',
    noteMax: 100,
  })
  assert.equal(entry.payload.title, '工具 bash')
  assert.equal(entry.payload.note, '')
  assert.equal(entry.payload.outcome, 'bash')
  assert.equal(entry.tags.kind, 'tool')
  assert.equal(entry.tags.tool, 'bash')
  assert.equal(entry.tags.call, 'call-1')
  assert.equal(entry.tags.error, undefined)
})

test('toolEntry full mode keeps clipped arguments and result', () => {
  const entry = toolEntry(subject, {
    turn: 1,
    step: 2,
    callId: 'call-2',
    name: 'read',
    args: { path: '/tmp/a.txt' },
    result: 'y'.repeat(400),
    isError: true,
    mode: 'full',
    noteMax: 200,
  })
  assert.ok(entry.payload.note.includes('arguments: '))
  assert.ok(entry.payload.note.includes('/tmp/a.txt'))
  assert.ok(entry.payload.note.includes('result: '))
  assert.ok(entry.payload.note.length <= 400, 'note must respect the cap')
  assert.equal(entry.tags.error, 'true')
  assert.ok(entry.payload.title.includes('出错'))
})

test('toolEntry full mode survives absent or circular arguments', () => {
  const noArgs = toolEntry(subject, { turn: 1, callId: 'c', name: 'noop', mode: 'full', noteMax: 100 })
  assert.equal(noArgs.payload.note, '')

  const circular = { a: 1 }
  circular.self = circular
  const entry = toolEntry(subject, { turn: 1, callId: 'c', name: 'loop', args: circular, mode: 'full', noteMax: 100 })
  assert.equal(entry.payload.note, '')
})

test('resolveConfig defaults to an empty workspace list', () => {
  const cfg = resolveConfig({}, {})
  assert.deepEqual(cfg.fullContextWorkspaces, [])
  assert.equal(cfg.sayNoteMax, 20000)
  assert.equal(cfg.toolNoteMax, 2000)
  assert.equal(isFullContextWorkspace('/home/ystyle/notes', cfg), false)
  assert.equal(workspaceLevelFor('/home/ystyle/notes', cfg), null)
})

test('resolveConfig reads the workspace list from config and env', () => {
  const fromConfig = resolveConfig({ fullContextWorkspaces: '/a = full\nb' }, {})
  assert.deepEqual(fromConfig.fullContextWorkspaces, [
    { path: '/a', level: 'full' },
    { path: 'b', level: 'names' },
  ])
  assert.equal(workspaceLevelFor('/x/b', fromConfig), 'names')

  const fromEnv = resolveConfig({}, { DSH_MEM_BRIDGE_FULL_CONTEXT: '/env/only = none' })
  assert.deepEqual(fromEnv.fullContextWorkspaces, [{ path: '/env/only', level: 'none' }])
  assert.equal(workspaceLevelFor('/env/only', fromEnv), 'none')
})

test('resolveConfig accepts an already-structured array from the settings page', () => {
  const cfg = resolveConfig({ fullContextWorkspaces: [{ path: '/a', level: 'full' }] }, {})
  assert.deepEqual(cfg.fullContextWorkspaces, [{ path: '/a', level: 'full' }])
})

test('resolveConfig keeps a workspace whose level was mistyped', () => {
  // Losing the whole workspace over a typo would silently stop recording a
  // session the user meant to record; recording one level off is the cheaper error.
  const cfg = resolveConfig({ fullContextWorkspaces: '/a = evreything' }, {})
  assert.deepEqual(cfg.fullContextWorkspaces, [{ path: '/a', level: 'names' }])
  assert.equal(workspaceLevelFor('/a', cfg), 'names')
})


// ---------------------------------------------------------------------------
// Type specs and self-healing arguments
// ---------------------------------------------------------------------------

test('typeSpecs covers the activity type and the transcript type', () => {
  const cfg = resolveConfig({}, {})
  const specs = typeSpecs(cfg)
  assert.deepEqual(specs.map((spec) => spec.name), ['dsh/activity', 'dsh/chat'])
  assert.deepEqual(specs[0].levels, ['day', 'week'])
  // A transcript is high-frequency, so it keeps sub-day windows.
  assert.deepEqual(specs[1].levels, ['1h', 'day', 'week'])
  assert.equal(specs[1].autoSummarize, true)
  assert.deepEqual(specs[1].summaryGroupBy, ['proj'])
})

test('typeSpecs follows the configured type names', () => {
  const cfg = resolveConfig({ type: 'x/act', chatType: 'x/chat' }, {})
  assert.deepEqual(typeSpecs(cfg).map((spec) => spec.name), ['x/act', 'x/chat'])
})

test('typeCreateArgs sends levels, update does not', () => {
  const spec = typeSpecs(resolveConfig({}, {}))[1]
  const create = typeCreateArgs(spec)
  assert.deepEqual(create.levels, ['1h', 'day', 'week'])

  const revive = typeReviveArgs(spec)
  assert.equal(revive.levels, undefined, 'mem/type_update refuses to change levels')
  assert.equal(revive.name, create.name)
  assert.equal(revive.auto_summarize, true)
})

test('isTypeExistsFailure recognises the tower wording and nothing else', () => {
  assert.equal(isTypeExistsFailure('tool error: 类型已存在: dsh/chat（要改配置用 mem/type_update）'), true)
  assert.equal(isTypeExistsFailure('类型已存在'), true)
  assert.equal(isTypeExistsFailure('Type dsh/chat already exists'), true)
  // Anything else must not be mistaken for "already there": treating a real
  // failure as success would leave the type missing and every write dropped.
  assert.equal(isTypeExistsFailure('tool error: 类型不存在: dsh/chat'), false)
  assert.equal(isTypeExistsFailure('HTTP 500 Internal Server Error'), false)
  assert.equal(isTypeExistsFailure(''), false)
  assert.equal(isTypeExistsFailure(null), false)
})

test('resolveConfig exposes the transcript type with its own default', () => {
  assert.equal(resolveConfig({}, {}).chatType, TYPE_CHAT)
  assert.equal(resolveConfig({}, { DSH_MEM_BRIDGE_CHAT_TYPE: 'env/chat' }).chatType, 'env/chat')
  assert.equal(resolveConfig({ chatType: 'cfg/chat' }, {}).chatType, 'cfg/chat')
})
