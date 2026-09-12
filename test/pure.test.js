import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  KIND,
  TYPE_ACTIVITY,
  appendRequest,
  blockKinds,
  callRequest,
  clipText,
  closeEntry,
  compactEntry,
  compactTags,
  errorEntry,
  firstLine,
  goalEntry,
  isRetryableWriteFailure,
  isSubstantiveTurn,
  lifecycleEntry,
  mcpHeaders,
  mcpUrl,
  milestoneEntry,
  parseMcpBody,
  projFromCwd,
  resolveConfig,
  resultText,
  rpcFailure,
  textOfBlocks,
  titleEntry,
  turnEntry,
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
  const e = closeEntry(subject, { goalId: 'g-1', outcome: '3 个提交', next: '装包', note: '收口叙述' })
  assert.equal(e.tags.kind, KIND.close)
  assert.equal(e.tags.goal, 'g-1')
  assert.equal(e.payload.outcome, '3 个提交')
  assert.equal(e.payload.next, '装包')
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
