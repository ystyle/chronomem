/**
 * Wiring tests for the plugin half.
 *
 * `lib/index.js` is the only part that can break a dsh boot, and it is the only
 * part the pure tests cannot reach. These tests drive it with a fake Cordis
 * context and a stubbed `fetch`, so they prove — without a running dsh — that
 * apply() registers the expected listeners, that a completed turn becomes one
 * append, that the noise is filtered, and that a disabled plugin does nothing.
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'

import plugin, { apply } from '../lib/index.js'

/** A fake Cordis context capturing listeners and effects. */
function fakeCtx(services = {}) {
  const listeners = new Map()
  const effects = []
  return {
    listeners,
    effects,
    on(name, handler) {
      listeners.set(name, handler)
      return () => listeners.delete(name)
    },
    effect(callback) {
      effects.push(callback)
      const dispose = callback()
      return typeof dispose === 'function' ? dispose : () => {}
    },
    get(name) {
      return services[name]
    },
    emit(name, ...args) {
      const handler = listeners.get(name)
      if (handler === undefined) throw new Error(`no listener for ${name}`)
      return handler(...args)
    },
  }
}

/** A stub `llm` service that streams back one canned reply. */
function stubLlm(reply, calls = []) {
  return {
    stream(options) {
      calls.push(options)
      return (async function* generate() {
        yield { type: 'text-delta', index: 0, text: reply }
        yield { type: 'finish', reason: { kind: 'stop' } }
      })()
    },
  }
}

/** A stub host default-model service. */
function stubModel(provider = 'stub-provider', model = 'stub-model') {
  return { currentSelection: () => ({ provider, model }) }
}

/** Capture the requests a plugin run issues. */
function withStubbedFetch(run) {
  const calls = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) })
    return {
      ok: true,
      status: 200,
      statusText: 'OK',
      text: async () => JSON.stringify({ jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: 'ok' }] } }),
    }
  }
  return Promise.resolve()
    .then(run)
    .finally(() => {
      globalThis.fetch = original
    })
    .then(() => calls)
}

const settled = () => new Promise((resolve) => {
  setTimeout(resolve, 25)
})

const session = { id: 'session-1', header: { cwd: '/home/ystyle/Projects/Cangjie/chronomem' } }

function assistantEvent(turn, text) {
  return {
    type: 'assistant/message',
    seq: 1,
    time: 1704110400000,
    data: { turn, step: 1, message: { content: [{ type: 'reasoning', text: 'scratch' }, { type: 'text', text }] } },
  }
}

function toolCallEvent(turn) {
  return { type: 'tool/call', seq: 2, time: 1704110400001, data: { turn, step: 1, name: 'bash' } }
}

function turnEndEvent(turn, reason = 'completed') {
  return { type: 'turn/end', seq: 3, time: 1704110400002, data: { turn, reason: { kind: reason } } }
}

test('the module exports a Cordis plugin in both shapes', () => {
  assert.equal(typeof apply, 'function')
  assert.equal(typeof plugin.apply, 'function')
  assert.equal(plugin.name, 'dsh-mem-bridge')
})

test('a disabled plugin registers nothing', () => {
  const ctx = fakeCtx()
  apply(ctx, { enabled: false })
  assert.equal(ctx.listeners.size, 0)
})

test('apply registers the five listeners and never throws', () => {
  const ctx = fakeCtx()
  assert.doesNotThrow(() => apply(ctx, { url: 'http://127.0.0.1:9', projMap: {} }))
  for (const name of ['session/event', 'agent/session-start', 'goal/changed', 'subagent/end', 'agent/error']) {
    assert.equal(typeof ctx.listeners.get(name), 'function', `missing listener ${name}`)
  }
})

test('a completed substantive turn becomes exactly one dsh/activity append', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {}, turnMinTools: 1, turnMinLen: 120, turnNoteMax: 6000 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, assistantEvent(7, '结论：可以开始'))
    ctx.emit('session/event', session, toolCallEvent(7))
    ctx.emit('session/event', session, turnEndEvent(7))
    await settled()
  })

  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, 'http://tower.test/mcp')
  assert.equal(calls[0].body.params.name, 'mem/append')
  const args = calls[0].body.params.arguments
  assert.equal(args.type, 'dsh/activity')
  assert.equal(args.tags.kind, 'turn')
  assert.equal(args.tags.turn, '7')
  assert.equal(args.tags.session, 'session-1')
  assert.equal(args.tags.proj, 'chronomem', 'proj comes from session.header.cwd')
  assert.equal(args.payload.note, '结论：可以开始')
  assert.equal(args.payload.stats, 'tools=1')
})

test('a turn keeps only the LAST assistant text, not the intermediate narration', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', turnMinTools: 1, turnMinLen: 120 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, assistantEvent(2, '先看看文件'))
    ctx.emit('session/event', session, toolCallEvent(2))
    ctx.emit('session/event', session, assistantEvent(2, '最终结论：改好了'))
    ctx.emit('session/event', session, turnEndEvent(2))
    await settled()
  })
  assert.equal(calls.length, 1)
  assert.equal(calls[0].body.params.arguments.payload.note, '最终结论：改好了')
})

test('non-substantive and non-completed turns are dropped', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', turnMinTools: 1, turnMinLen: 120 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, assistantEvent(1, '好的')) // no tools, short => noise
    ctx.emit('session/event', session, turnEndEvent(1))
    ctx.emit('session/event', session, assistantEvent(2, 'x'.repeat(500)))
    ctx.emit('session/event', session, turnEndEvent(2, 'aborted')) // aborted => dropped
    await settled()
  })
  assert.equal(calls.length, 0)
})

test('a pure-discussion turn (no tools, long text) is recorded — D10 OR semantics', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', turnMinTools: 1, turnMinLen: 120 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, assistantEvent(3, 'y'.repeat(300)))
    ctx.emit('session/event', session, turnEndEvent(3))
    await settled()
  })
  assert.equal(calls.length, 1)
  assert.equal(calls[0].body.params.arguments.tags.turn, '3')
})

test('session/title keeps the fallback only until a real title arrives', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, {
      type: 'session/title',
      seq: 10,
      time: 1704110400000,
      data: { title: '@docs/plans/2026-09-05-dsh-session-memo', messageSeqs: [5], source: { kind: 'fallback' } },
    })
    ctx.emit('session/event', session, {
      type: 'session/title',
      seq: 12,
      time: 1704110400001,
      data: { title: '检查忆时塔会话记忆计划', messageSeqs: [5], source: { kind: 'provider', provider: 'x', model: 'y' } },
    })
    await settled()
  })
  const titles = calls.map((c) => c.body.params.arguments.payload.title)
  assert.deepEqual(titles, ['@docs/plans/2026-09-05-dsh-session-memo', '检查忆时塔会话记忆计划'])

  // A second fallback frame must not add another entry.
  const again = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, {
      type: 'session/title',
      seq: 14,
      time: 1704110400002,
      data: { title: 'again', messageSeqs: [5], source: { kind: 'fallback' } },
    })
    await settled()
  })
  assert.equal(again.length, 0)
})

test('compaction/summary becomes kind=compact, and compaction/prune is ignored', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, {
      type: 'compaction/prune',
      seq: 20,
      time: 1704110400000,
      data: { shadowedRange: { start: 1, end: 1 }, shadowedSeqs: [1], shadowedTokenCount: 10 },
    })
    ctx.emit('session/event', session, {
      type: 'compaction/summary',
      seq: 21,
      time: 1704110400001,
      data: {
        compactionId: 'cid-1',
        summary: [{ type: 'text', text: '早期历史要点' }],
        shadowedRange: { start: 100, end: 200 },
        shadowedSeqs: [100, 101],
        shadowedTokenCount: 4242,
      },
    })
    await settled()
  })
  assert.equal(calls.length, 1)
  const args = calls[0].body.params.arguments
  assert.equal(args.tags.kind, 'compact')
  assert.equal(args.tags.span, '100..200')
  assert.equal(args.tags.cid, 'cid-1')
  assert.equal(args.payload.note, '早期历史要点')
})

test('agent/session-start, goal/changed, subagent/end and agent/error each append', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('agent/session-start', { agent: { id: 'session-1' }, source: 'startup' })
    ctx.emit('goal/changed', {
      agent: { id: 'session-1' },
      change: { operation: 'block', ref: { id: 'goal-1', revision: 4 }, goal: { phase: 'blocked', objective: '搭好桥', blockedReason: { code: 'AUTH', message: 'AUTH missing' } } },
    })
    ctx.emit('subagent/end', { runId: 'run-1', id: 'session-9', provider: 'in-process', local: true, stopReason: 'completed', lastAssistantMessage: [{ type: 'text', text: '子代理汇报' }] })
    ctx.emit('agent/error', { agent: { id: 'session-1' }, turn: 5, step: 2, error: { code: 'LLM_TIMEOUT', message: 'boom' } })
    await settled()
  })
  const kinds = calls.map((c) => c.body.params.arguments.tags.kind)
  assert.deepEqual(kinds, ['open', 'goal', 'milestone', 'error'])

  const goal = calls[1].body.params.arguments
  assert.equal(goal.tags.goal, 'goal-1')
  assert.equal(goal.tags.rev, '4')
  assert.equal(goal.tags.phase, 'blocked')
  assert.equal(goal.payload.blocker, 'AUTH missing')

  const milestone = calls[2].body.params.arguments
  assert.equal(milestone.tags.session, 'session-9')
  assert.equal(milestone.tags.role, 'subagent')
  assert.equal(milestone.payload.note, '子代理汇报')

  const error = calls[3].body.params.arguments
  assert.equal(error.payload.blocker, 'LLM_TIMEOUT')
  assert.equal(error.tags.session, 'session-1')
})

test('a failing tower never throws into the caller and the queue stays bounded', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', queueMax: 2, retryMax: 1, retryBackoffMs: 0 })
  const original = globalThis.fetch
  let attempts = 0
  globalThis.fetch = async () => {
    attempts += 1
    throw new Error('ECONNREFUSED')
  }
  try {
    assert.doesNotThrow(() => {
      for (let i = 0; i < 5; i += 1) {
        ctx.emit('session/event', session, {
          type: 'session/title',
          seq: 30 + i,
          time: 1704110400000 + i,
          data: { title: `t${i}`, source: { kind: 'provider' } },
        })
      }
    })
    await settled()
    await settled()
  } finally {
    globalThis.fetch = original
  }
  // Nothing escaped (no throw above), the writer did try the tower, and the
  // bounded queue means the attempt count is far below "one per entry forever".
  assert.ok(attempts >= 1, 'the writer should have attempted at least one append')
  assert.ok(attempts <= 4, `queue bound should cap attempts, saw ${attempts}`)
})

// ---------------------------------------------------------------- D17 lifecycle

test('a restart-restored session nobody touches writes no resume entry', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withStubbedFetch(async () => {
    // A restart announces every restored session; none of them is used here.
    for (const id of ['session-a', 'session-b', 'session-c']) {
      ctx.emit('agent/session-start', { agent: { id }, source: 'resume' })
    }
    await settled()
  })
  assert.equal(calls.length, 0, 'idle resumes must not reach the tower')
})

test('a restored session that is used writes exactly one resume entry', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', turnMinTools: 1, turnMinLen: 120 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('agent/session-start', { agent: { id: 'session-1' }, source: 'resume' })
    ctx.emit('session/event', session, assistantEvent(1, 'z'.repeat(200)))
    ctx.emit('session/event', session, turnEndEvent(1))
    await settled()
  })
  const kinds = calls.map((c) => c.body.params.arguments.tags.kind)
  assert.deepEqual(kinds, ['resume', 'turn'], 'resume is flushed before the turn entry')
  assert.equal(calls[0].body.params.arguments.tags.session, 'session-1')
  assert.equal(calls[0].body.params.arguments.tags.proj, 'chronomem', 'flushed with the proj learned from the session')
})

test('duplicate session-start announcements collapse to one entry', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('agent/session-start', { agent: { id: 'session-1' }, source: 'resume' })
    ctx.emit('agent/session-start', { agent: { id: 'session-1' }, source: 'resume' })
    ctx.emit('session/event', session, { type: 'step/start', seq: 1, time: 1704110400000, data: { turn: 1, step: 1 } })
    await settled()
  })
  assert.equal(calls.length, 1)
  assert.equal(calls[0].body.params.arguments.tags.kind, 'resume')
})

test('a startup session opens immediately and only once', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('agent/session-start', { agent: { id: 'session-1' }, source: 'startup' })
    ctx.emit('agent/session-start', { agent: { id: 'session-1' }, source: 'startup' })
    await settled()
  })
  assert.equal(calls.length, 1, 'open is immediate but deduplicated')
  assert.equal(calls[0].body.params.arguments.tags.kind, 'open')
})

// ---------------------------------------------------------------- write semantics

test('an ambiguous timeout is NOT retried — a duplicate is worse than a miss', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', retryMax: 5, retryBackoffMs: 0 })
  const original = globalThis.fetch
  let attempts = 0
  globalThis.fetch = async () => {
    attempts += 1
    const error = new Error('This operation was aborted')
    error.name = 'AbortError'
    throw error
  }
  try {
    ctx.emit('session/event', session, {
      type: 'session/title',
      seq: 1,
      time: 1704110400000,
      data: { title: 't', source: { kind: 'provider' } },
    })
    await settled()
    await settled()
  } finally {
    globalThis.fetch = original
  }
  assert.equal(attempts, 1, '忆时塔 may have applied the append; repeating it would duplicate the entry')
})

test('a connect failure IS retried up to retryMax', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', retryMax: 3, retryBackoffMs: 0 })
  const original = globalThis.fetch
  let attempts = 0
  globalThis.fetch = async () => {
    attempts += 1
    const error = new TypeError('fetch failed')
    error.cause = { code: 'ECONNREFUSED' }
    throw error
  }
  try {
    ctx.emit('session/event', session, {
      type: 'session/title',
      seq: 1,
      time: 1704110400000,
      data: { title: 't', source: { kind: 'provider' } },
    })
    await settled()
    await settled()
  } finally {
    globalThis.fetch = original
  }
  assert.equal(attempts, 3, 'the tower being down is safe to retry')
})

// ---------------------------------------------------------------- L2b close / workflow

/** Route the stubbed fetch by MCP tool name so query and append can differ. */
function withRoutedFetch(handlers, run) {
  const calls = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body)
    const tool = body.params.name
    calls.push({ url, body, tool })
    const text = handlers[tool] === undefined ? 'ok' : handlers[tool]
    return {
      ok: true,
      status: 200,
      statusText: 'OK',
      text: async () => JSON.stringify({
        jsonrpc: '2.0',
        id: body.id,
        result: { content: [{ type: 'text', text }] },
      }),
    }
  }
  return Promise.resolve()
    .then(run)
    .finally(() => {
      globalThis.fetch = original
    })
    .then(() => calls)
}

function goalEvent(operation, { id = 'goal-1', revision = 3, phase = 'complete', objective = '搭好桥' } = {}) {
  return {
    agent: { id: 'session-1' },
    change: {
      operation,
      ref: { id, revision },
      goal: { phase, objective },
    },
  }
}

const CLOSE_REPLY = '{"outcome":"3 个提交 + 一次部署","next":"接 L2b 之后的里程碑","note":"完成并发修复并部署。"}'

test('goal complete distills a close entry from the tower timeline', async () => {
  const llmCalls = []
  const ctx = fakeCtx({ llm: stubLlm(CLOSE_REPLY, llmCalls), agentDefaultModel: stubModel() })
  apply(ctx, { url: 'http://tower.test', tailN: 20, maxDaily: 20 })
  const calls = await withRoutedFetch({ 'mem/query': '[09-12 22:00] {"note":"一条流水"} <kind=turn>' }, async () => {
    ctx.emit('session/event', session, assistantEvent(1, 'z'.repeat(200)))
    ctx.emit('session/event', session, turnEndEvent(1))
    ctx.emit('goal/changed', goalEvent('complete'))
    await settled()
    await settled()
    await settled()
  })

  const query = calls.find((c) => c.tool === 'mem/query')
  assert.ok(query, 'distillation must read the tower timeline')
  assert.equal(query.body.params.arguments.tag, 'session=session-1')
  assert.equal(query.body.params.arguments.limit, 20)

  assert.equal(llmCalls.length, 1, 'exactly one model call')
  assert.equal(llmCalls[0].provider, 'stub-provider', 'falls back to the host default route')
  assert.equal(llmCalls[0].model, 'stub-model')
  assert.match(llmCalls[0].messages[0].content[0].text, /搭好桥/)

  const close = calls.find((c) => c.tool === 'mem/append' && c.body.params.arguments.tags.kind === 'close')
  assert.ok(close, 'a close entry must be appended')
  assert.equal(close.body.params.arguments.tags.distilled, 'true')
  assert.equal(close.body.params.arguments.tags.goal, 'goal-1')
  assert.equal(close.body.params.arguments.payload.outcome, '3 个提交 + 一次部署')
  assert.equal(close.body.params.arguments.payload.next, '接 L2b 之后的里程碑')
  assert.equal(close.body.params.arguments.payload.title, '搭好桥')
})

test('a second goal completion in the same session degrades to a skeleton', async () => {
  const llmCalls = []
  const ctx = fakeCtx({ llm: stubLlm(CLOSE_REPLY, llmCalls), agentDefaultModel: stubModel() })
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withRoutedFetch({ 'mem/query': 'timeline' }, async () => {
    ctx.emit('goal/changed', goalEvent('complete', { id: 'goal-1' }))
    await settled()
    await settled()
    ctx.emit('goal/changed', goalEvent('complete', { id: 'goal-2' }))
    await settled()
    await settled()
  })
  assert.equal(llmCalls.length, 1, 'one distillation per session')
  const closes = calls.filter((c) => c.tool === 'mem/append' && c.body.params.arguments.tags.kind === 'close')
  assert.equal(closes.length, 2, 'the second completion still records a fact')
  assert.equal(closes[0].body.params.arguments.tags.distilled, 'true')
  assert.equal(closes[1].body.params.arguments.tags.distilled, 'false')
  assert.match(closes[1].body.params.arguments.payload.note, /骨架收口/)
})

test('without a usable model route the close entry is a skeleton and nothing is queried', async () => {
  const ctx = fakeCtx() // 无 llm / 无 agentDefaultModel
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withRoutedFetch({}, async () => {
    ctx.emit('goal/changed', goalEvent('complete'))
    await settled()
    await settled()
  })
  assert.equal(calls.filter((c) => c.tool === 'mem/query').length, 0, 'no model route => no tower read')
  const close = calls.find((c) => c.tool === 'mem/append' && c.body.params.arguments.tags.kind === 'close')
  assert.ok(close)
  assert.equal(close.body.params.arguments.tags.distilled, 'false')
})

test('distill=false turns the aggregate account off entirely', async () => {
  const llmCalls = []
  const ctx = fakeCtx({ llm: stubLlm(CLOSE_REPLY, llmCalls), agentDefaultModel: stubModel() })
  apply(ctx, { url: 'http://tower.test', distill: false })
  const calls = await withRoutedFetch({ 'mem/query': 'timeline' }, async () => {
    ctx.emit('goal/changed', goalEvent('complete'))
    await settled()
    await settled()
  })
  assert.equal(llmCalls.length, 0)
  assert.equal(calls.filter((c) => c.tool === 'mem/query').length, 0)
  const close = calls.find((c) => c.tool === 'mem/append' && c.body.params.arguments.tags.kind === 'close')
  assert.equal(close.body.params.arguments.tags.distilled, 'false')
})

test('the daily budget caps model calls', async () => {
  const llmCalls = []
  const ctx = fakeCtx({ llm: stubLlm(CLOSE_REPLY, llmCalls), agentDefaultModel: stubModel() })
  apply(ctx, { url: 'http://tower.test', maxDaily: 1 })
  const calls = await withRoutedFetch({ 'mem/query': 'timeline' }, async () => {
    ctx.emit('goal/changed', goalEvent('complete', { id: 'g-a' }))
    await settled()
    await settled()
    ctx.emit('goal/changed', goalEvent('complete', { id: 'g-b' }))
    await settled()
    await settled()
  })
  assert.equal(llmCalls.length, 1, 'only one call fits the daily budget')
  const closes = calls.filter((c) => c.tool === 'mem/append' && c.body.params.arguments.tags.kind === 'close')
  assert.equal(closes[1].body.params.arguments.tags.distilled, 'false')
})

test('workflow/end records a fact milestone tagged role=workflow', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test' })
  const calls = await withRoutedFetch({}, async () => {
    ctx.emit('workflow/end',
      { id: 'wf-1', meta: { name: 'audit-fanout', description: '并行审计' } },
      { stopReason: 'completed', agentsStarted: 7 })
    await settled()
  })
  const entry = calls.find((c) => c.tool === 'mem/append')
  assert.ok(entry, 'workflow end must be recorded')
  const args = entry.body.params.arguments
  assert.equal(args.tags.kind, 'milestone')
  assert.equal(args.tags.role, 'workflow')
  assert.equal(args.tags.run, 'wf-1')
  assert.match(args.payload.title, /audit-fanout/)
  assert.match(args.payload.note, /stopReason=completed/)
  assert.match(args.payload.note, /agentsStarted=7/)
  assert.equal(args.payload.outcome, 'completed')
})
