/**
 * Wiring tests for the plugin half.
 *
 * `lib/index.js` is the only part that can break a dsh boot, and it is the only
 * part the pure tests cannot reach. These tests drive it with a fake Cordis
 * context and a stubbed `fetch`, so they prove — without a running dsh — that
 * apply() registers the expected listeners, that a completed turn becomes one
 * append, that the noise is filtered, and that a disabled plugin does nothing.
 */

import { afterEach, test } from 'node:test'
import assert from 'node:assert/strict'

import * as bridge from '../lib/index.js'
import { mcpHeaders, resolveConfig } from '../lib/pure.js'

const plugin = bridge.default
const applyPlugin = bridge.apply

/**
 * The type bootstrap `ctx`'s mount started, or `null` when it never began.
 *
 * Read through the namespace with `?.` on purpose: without the export the file
 * still loads and runs, so a build lacking the handle fails these tests on
 * their behaviour (a stray request reaching the next tower) rather than on a
 * missing-binding import error.
 */
function typesReadyOf(ctx) {
  return bridge.typesReady?.(ctx) ?? null
}

/**
 * Type bootstraps the mounts in this file left in flight, so no test inherits
 * one.
 *
 * `apply()` publishes its type self-heal instead of returning it (a returned
 * promise becomes part of the mount — see `TYPES_READY` in `lib/index.js`),
 * so that work outlives the call. A test that finishes while the bootstrap is
 * still running leaves a request to be dispatched later, into whatever `fetch`
 * is installed *then* — and the next test's tower would record it as its own.
 * Draining here, with a tower that fails at once, answers every such leftover
 * while no test is asserting, so it can reach neither the network nor a later
 * stub. Returns what the leftover requests were, for the regression test.
 */
async function drainBootstraps() {
  const pending = bootstraps.splice(0).filter((promise) => promise !== null)
  if (pending.length === 0) return []
  const strayed = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    strayed.push({ url: String(url), body: JSON.parse(init.body) })
    throw new TypeError('fetch failed')
  }
  try {
    await Promise.all(pending)
  } finally {
    globalThis.fetch = original
  }
  return strayed
}

const bootstraps = []

/** Mount the plugin, keeping the bootstrap it leaves behind. */
function apply(ctx, config) {
  const returned = applyPlugin(ctx, config)
  bootstraps.push(typesReadyOf(ctx))
  return returned
}

afterEach(drainBootstraps)

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

/**
 * Capture the requests a plugin run issues.
 *
 * Mounting the plugin also fires a one-shot type self-heal (`mem/type_create` /
 * `mem/type_update`), which must not inflate the entry counts these tests assert
 * on — so only `mem/append` is collected unless a test asks for everything.
 */
function withStubbedFetch(run, { all = false } = {}) {
  const calls = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body)
    if (all || body.params.name === 'mem/append') calls.push({ url, body })
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

function turnStartEvent(turn) {
  return { type: 'turn/start', seq: 0, time: 1704110399999, data: { turn } }
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
  globalThis.fetch = async (url, init) => {
    // Only the append counts: the mount-time type self-heal is a separate path.
    if (JSON.parse(init.body).params.name === 'mem/append') attempts += 1
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
  globalThis.fetch = async (url, init) => {
    if (JSON.parse(init.body).params.name === 'mem/append') attempts += 1
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

// ── Config schema (design doc D16② / §282) ───────────────────────────────────
//
// The settings form projects exactly the `.volatile()` fields, so the schema —
// not the README — is the contract for what a user can reach in the Web UI.
// These tests pin that contract and the volatile-unwrapping boundary.

/**
 * The root schema node of a schemastery `toJSON()`.
 *
 * `toJSON()` is a flat `uid` + `refs` pool; the root object is the last ref and
 * holds the field-name → ref-id `dict`.
 */
function rootNode(schema) {
  const json = schema.toJSON()
  const refs = json.refs ?? {}
  const ids = Object.keys(refs)
  return refs[ids[ids.length - 1]] ?? {}
}

/** Field names of a schemastery object's root dict, in declaration order. */
function schemaFieldNames(schema) {
  return Object.keys(rootNode(schema).dict ?? {})
}

/** Resolve one field's metadata through the schema's `refs` indirection. */
function fieldMeta(schema, field) {
  const json = schema.toJSON()
  const ref = (rootNode(schema).dict ?? {})[field]
  return (json.refs ?? {})[ref]?.meta ?? {}
}

test('Config declares exactly the five fields the settings form shows', () => {
  // D16②/§282 pinned four: service address, auth key, master switch,
  // distillation switch. `fullContextWorkspaces` is the fifth, added because
  // choosing *which* workspaces keep a transcript is a deployment decision a
  // user has to be able to make from the UI. Every other knob stays off the form.
  assert.deepEqual(
    schemaFieldNames(plugin.Config).sort(),
    ['distill', 'enabled', 'fullContextWorkspaces', 'token', 'url'],
    'only the designed fields belong on the settings form',
  )
})

test('every form field is volatile, or the settings form would not show it', () => {
  // The settings projection exposes only `.volatile()` fields (dsh-settings
  // README: "Forms expose only volatile fields"). A non-volatile field here
  // would silently disappear from the UI, so pin it.
  for (const field of schemaFieldNames(plugin.Config)) {
    assert.equal(fieldMeta(plugin.Config, field).volatile, true, `${field} must be volatile`)
  }
})

test('Config marks token as a secret so the form redacts it', () => {
  assert.equal(fieldMeta(plugin.Config, 'token').role, 'secret', 'token must carry the secret role')
})

test('Config defaults match the documented values', () => {
  const cfg = plugin.Config({})
  assert.equal(cfg.url.get(), 'http://127.0.0.1:8900')
  assert.equal(cfg.enabled.get(), true)
  assert.equal(cfg.distill.get(), true)
})

test('token carries no default, so an unset key does not read as configured', () => {
  // The settings form derives "configured" from whether the resolved value is
  // present at all (`redactSecrets` records presence, not content). A
  // `.default('')` would make the resolved value present on every fresh
  // install, so the form would claim a key nobody ever set. Absence is the
  // honest state; the writer turns it into '' at the boundary.
  const meta = fieldMeta(plugin.Config, 'token')
  assert.equal(meta.default, undefined, 'token must not declare a default')
  assert.equal(plugin.Config({}).token.get(), undefined, 'an unset token resolves to absence')
})

test('an absent token still produces the documented empty-string config', () => {
  // `resolveConfig` is value-based and owns the '' fallback, so the wire
  // behaviour is unchanged: no Authorization header without a token.
  const effective = resolveConfig({ url: 'http://127.0.0.1:8900' }, {})
  assert.equal(effective.token, '')
  assert.equal(mcpHeaders(effective.token).authorization, undefined, 'no header without a token')
})

test('a form field is a live reference read at use time, not a snapshot', () => {
  // The form writes through the profile, and the plugin keeps running: it must
  // observe the new value without a re-mount. That is what reading `.get()` at
  // each use site buys — a snapshot taken in apply() would go stale.
  const cfg = plugin.Config({ url: 'http://first.test' })
  assert.equal(cfg.url.get(), 'http://first.test')
  assert.equal(typeof cfg.url.get, 'function', 'volatile fields expose .get()')
})

test('a plain (non-volatile) config value is accepted unchanged', () => {
  const ctx = fakeCtx()
  // A profile entry may still carry plain values (older composition, or a key
  // added after this schema). Passing them must not throw.
  assert.doesNotThrow(() => apply(ctx, { url: 'http://plain.test', enabled: false, turnNoteMax: 123 }))
})

test('a plain config value is honoured, not dropped by the unwrapping boundary', async () => {
  // Guards plainConfig(): a plain `url` must survive into the writer, otherwise
  // every pre-schema composition entry would silently fall back to localhost.
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://plain.test' })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('agent/session-start', { agent: { id: 'session-1' }, source: 'startup' })
    await settled()
  })
  assert.ok(calls.length > 0, 'a plain config must still record')
})

test('disabled through a volatile reference stops all recording', () => {
  const ctx = fakeCtx()
  const cfg = plugin.Config({ url: 'http://tower.test', enabled: false })
  apply(ctx, cfg)
  // apply() returns early when disabled, so it registers no listeners at all.
  assert.equal(ctx.listeners.size, 0, 'a disabled plugin must register nothing')
})

// ---------------------------------------------------------------------------
// Full-context workspaces
//
// The regression that matters most is the default one: with an empty workspace
// list a session must keep producing exactly what it produced before this
// feature existed. These tests pin both halves of that.
// ---------------------------------------------------------------------------

const FULL_CTX_CWD = '/home/ystyle/notes'
const fullCtxSession = { id: 'session-2', header: { cwd: FULL_CTX_CWD } }

function userEvent(text, kind = 'user', surfaceOp = 'append') {
  return {
    type: 'user/message',
    seq: 4,
    time: 1704110400003,
    surfaceOp,
    data: { source: { kind }, content: [{ type: 'text', text }] },
  }
}

function assistantStepEvent(turn, step, text) {
  return {
    type: 'assistant/message',
    seq: 5,
    time: 1704110400004,
    data: { turn, step, message: { content: [{ type: 'text', text }] } },
  }
}

function toolCallEventWithId(turn, callId, name, args) {
  return {
    type: 'tool/call',
    seq: 6,
    time: 1704110400005,
    data: { turn, step: 2, callId, name, arguments: args },
  }
}

function toolResultEvent(turn, callId, text, isError = false) {
  return {
    type: 'tool/result',
    seq: 7,
    time: 1704110400006,
    data: {
      turn,
      step: 2,
      message: { source: { kind: 'tool', callId }, content: [{ type: 'text', text }] },
      ...(isError ? { error: { message: 'boom' } } : {}),
    },
  }
}

/** Collect the `kind` of every appended entry, in order. */
function kindsOf(calls) {
  return calls.map((call) => call.body.params.arguments.tags.kind)
}

test('an empty workspace list records no user message at all (default profile)', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {} })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, userEvent('你好'))
    await settled()
  })
  assert.deepEqual(kindsOf(calls), [])
})

test('the default profile still writes exactly one turn entry per completed turn', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {}, turnMinTools: 1, turnMinLen: 120 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', session, userEvent('你好'))
    ctx.emit('session/event', session, assistantEvent(7, '结论：可以开始'))
    ctx.emit('session/event', session, toolCallEvent(7))
    ctx.emit('session/event', session, turnEndEvent(7))
    await settled()
  })
  // Same single entry as before the feature: the user message is ignored and the
  // turn entry still comes from `turn/end`.
  assert.deepEqual(kindsOf(calls), ['turn'])
})

test('a full-context workspace records the transcript in order', async () => {
  const ctx = fakeCtx()
  apply(ctx, {
    url: 'http://tower.test',
    projMap: {},
    fullContextWorkspaces: `${FULL_CTX_CWD} = none`,
    sayNoteMax: 20000,
  })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, turnStartEvent(1))
    ctx.emit('session/event', fullCtxSession, userEvent('帮我看看这个配置'))
    ctx.emit('session/event', fullCtxSession, assistantStepEvent(1, 1, '我先读一下文件。'))
    ctx.emit('session/event', fullCtxSession, assistantStepEvent(1, 2, '读完了，配置没问题。'))
    ctx.emit('session/event', fullCtxSession, turnEndEvent(1))
    await settled()
  })

  assert.deepEqual(kindsOf(calls), ['user', 'say', 'say'])
  const args = calls.map((call) => call.body.params.arguments)
  assert.equal(args[0].payload.note, '帮我看看这个配置')
  assert.equal(args[1].payload.note, '我先读一下文件。')
  assert.equal(args[2].payload.note, '读完了，配置没问题。')
  assert.equal(args[0].tags.turn, '1')
  assert.equal(args[1].tags.step, '1')
  assert.equal(args[2].tags.step, '2')
  // `turn/end` must not add a duplicate of the last say entry.
  assert.ok(!kindsOf(calls).includes('turn'))
})

test('a full-context workspace ignores injected user-role messages', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {}, fullContextWorkspaces: `${FULL_CTX_CWD} = none` })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, userEvent('真的问题'))
    ctx.emit('session/event', fullCtxSession, userEvent('x'.repeat(5000), 'runtime-context'))
    ctx.emit('session/event', fullCtxSession, userEvent('x'.repeat(5000), 'skill-catalog'))
    ctx.emit('session/event', fullCtxSession, userEvent('x'.repeat(5000), 'time-context'))
    ctx.emit('session/event', fullCtxSession, userEvent('checkpoint', 'compact-checkpoint', { op: 'replace', startSeq: 1, endSeq: 9 }))
    await settled()
  })
  assert.deepEqual(kindsOf(calls), ['user'])
  assert.equal(calls[0].body.params.arguments.payload.note, '真的问题')
})

test('tool level none writes no tool entries', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {}, fullContextWorkspaces: `${FULL_CTX_CWD} = none` })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, toolCallEventWithId(1, 'call-1', 'bash', { command: 'ls' }))
    ctx.emit('session/event', fullCtxSession, toolResultEvent(1, 'call-1', 'a.txt'))
    await settled()
  })
  assert.deepEqual(kindsOf(calls), [])
})

test('tool level names records the name but drops arguments and output', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {}, fullContextWorkspaces: `${FULL_CTX_CWD} = names`, toolNoteMax: 2000 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, toolCallEventWithId(1, 'call-2', 'bash', { command: 'rm -rf /tmp/x' }))
    ctx.emit('session/event', fullCtxSession, toolResultEvent(1, 'call-2', 'x'.repeat(3000)))
    await settled()
  })
  assert.deepEqual(kindsOf(calls), ['tool'])
  const args = calls[0].body.params.arguments
  assert.equal(args.tags.tool, 'bash')
  assert.equal(args.tags.call, 'call-2')
  assert.equal(args.tags.turn, '1')
  assert.equal(args.payload.note, '', 'names mode must not leak arguments or output')
})

test('tool level full records clipped arguments and output', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {}, fullContextWorkspaces: `${FULL_CTX_CWD} = full`, toolNoteMax: 100 })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, toolCallEventWithId(1, 'call-3', 'read', { path: '/tmp/a.txt' }))
    ctx.emit('session/event', fullCtxSession, toolResultEvent(1, 'call-3', 'y'.repeat(300)))
    await settled()
  })
  assert.deepEqual(kindsOf(calls), ['tool'])
  const note = calls[0].body.params.arguments.payload.note
  assert.ok(note.includes('/tmp/a.txt'))
  assert.ok(note.includes('省略'), 'the output must be clipped, not stored whole')
})

test('a tool entry keeps the call timestamp rather than the result timestamp', async () => {
  const ctx = fakeCtx()
  apply(ctx, { url: 'http://tower.test', projMap: {}, fullContextWorkspaces: `${FULL_CTX_CWD} = names` })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, toolCallEventWithId(1, 'call-4', 'bash', {}))
    ctx.emit('session/event', fullCtxSession, toolResultEvent(1, 'call-4', 'done'))
    await settled()
  })
  // The call happened at ...005, its result at ...006: the entry belongs to the call.
  assert.equal(calls[0].body.params.arguments.ts, 1704110400005)
})

test('the workspace match uses the session cwd, not the agent id', async () => {
  const ctx = fakeCtx()
  apply(ctx, {
    url: 'http://tower.test',
    projMap: {},
    // Matches by last segment, so an absolute-cwd session under a different
    // root would not be picked up.
    fullContextWorkspaces: 'other-place = full',
  })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, userEvent('不该被记录'))
    await settled()
  })
  assert.deepEqual(kindsOf(calls), [])
})

// ---------------------------------------------------------------------------
// Type self-healing and the transcript type split
//
// A deployment that names a type 忆时塔 does not have records *nothing* before
// this: every append fails with "类型不存在" and is dropped after the retry
// budget, with only a counter to show for it. These tests pin the bootstrap and
// the split between the activity type and the transcript type.
// ---------------------------------------------------------------------------

/** A fetch stub that answers each tools/call by name, recording every request. */
function withScriptedTower(script) {
  const calls = []
  const urls = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body)
    calls.push(body)
    urls.push(String(url))
    const name = body.params.name
    const answer = script[name]
    if (answer === undefined) {
      return {
        ok: true,
        status: 200,
        statusText: 'OK',
        text: async () => JSON.stringify({ jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: 'ok' }] } }),
      }
    }
    return answer
  }
  return {
    calls,
    urls,
    restore: () => {
      globalThis.fetch = original
    },
  }
}

const okBody = () => ({
  ok: true,
  status: 200,
  statusText: 'OK',
  text: async () => JSON.stringify({ jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: 'ok' }] } }),
})
const toolErrorBody = (message) => ({
  ok: true,
  status: 200,
  statusText: 'OK',
  text: async () => JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    result: { content: [{ type: 'text', text: message }], isError: true },
  }),
})

test('mount creates both types on a fresh tower', async () => {
  const tower = withScriptedTower({ 'mem/type_create': okBody() })
  try {
    apply(fakeCtx(), { url: 'http://tower.test' })
    await settled()
    await settled()
  } finally {
    tower.restore()
  }
  const created = tower.calls.filter((call) => call.params.name === 'mem/type_create')
  assert.deepEqual(
    created.map((call) => call.params.arguments.name),
    ['dsh/activity', 'dsh/chat'],
  )
})

test('the transcript type is created with the hour-level chain', async () => {
  const tower = withScriptedTower({ 'mem/type_create': okBody() })
  try {
    apply(fakeCtx(), { url: 'http://tower.test' })
    await settled()
    await settled()
  } finally {
    tower.restore()
  }
  const chat = tower.calls.find(
    (call) => call.params.name === 'mem/type_create' && call.params.arguments.name === 'dsh/chat',
  )
  assert.deepEqual(chat.params.arguments.levels, ['1h', 'day', 'week'])
  assert.equal(chat.params.arguments.auto_summarize, true)
  assert.deepEqual(chat.params.arguments.summary_group_by, ['proj'])
})

test('an existing type falls through to type_update, without levels', async () => {
  const tower = withScriptedTower({
    'mem/type_create': toolErrorBody('类型已存在: dsh/chat（要改配置用 mem/type_update）'),
    'mem/type_update': okBody(),
  })
  try {
    apply(fakeCtx(), { url: 'http://tower.test' })
    await settled()
    await settled()
  } finally {
    tower.restore()
  }
  const updated = tower.calls.filter((call) => call.params.name === 'mem/type_update')
  assert.equal(updated.length, 2, 'both types should be revived')
  for (const call of updated) {
    assert.equal(
      call.params.arguments.levels,
      undefined,
      'levels must never be sent: 忆时塔 refuses to change it',
    )
  }
})

test('a tower without mem/type_update does not break the mount', async () => {
  const tower = withScriptedTower({
    'mem/type_create': toolErrorBody('类型已存在: dsh/activity'),
    'mem/type_update': toolErrorBody('未知工具: mem/type_update'),
  })
  try {
    assert.doesNotThrow(() => apply(fakeCtx(), { url: 'http://tower.test' }))
    await settled()
    await settled()
  } finally {
    tower.restore()
  }
})

test('a tower that cannot be reached does not break the mount', async () => {
  const original = globalThis.fetch
  globalThis.fetch = async () => {
    throw new TypeError('fetch failed')
  }
  try {
    assert.doesNotThrow(() => apply(fakeCtx(), { url: 'http://tower.test' }))
    await settled()
    await settled()
  } finally {
    globalThis.fetch = original
  }
})

test('transcript entries go to the chat type, activity entries to the activity type', async () => {
  const ctx = fakeCtx()
  apply(ctx, {
    url: 'http://tower.test',
    projMap: {},
    type: 'dsh/activity',
    chatType: 'dsh/chat',
    fullContextWorkspaces: '/home/ystyle/notes = names',
  })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, turnStartEvent(1))
    ctx.emit('session/event', fullCtxSession, userEvent('问题'))
    ctx.emit('session/event', fullCtxSession, assistantStepEvent(1, 1, '回答'))
    ctx.emit('session/event', fullCtxSession, toolCallEventWithId(1, 'c1', 'bash', {}))
    ctx.emit('session/event', fullCtxSession, toolResultEvent(1, 'c1', 'out'))
    ctx.emit('session/event', fullCtxSession, turnEndEvent(1))
    // A separate default-profile session still writes the activity type.
    ctx.emit('session/event', session, assistantEvent(4, 'x'.repeat(200)))
    ctx.emit('session/event', session, turnEndEvent(4))
    await settled()
  })

  const byType = calls.map((call) => [call.body.params.arguments.type, call.body.params.arguments.tags.kind])
  assert.deepEqual(byType, [
    ['dsh/chat', 'user'],
    ['dsh/chat', 'say'],
    ['dsh/chat', 'tool'],
    ['dsh/activity', 'turn'],
  ])
})

test('the chat type is configurable', async () => {
  const ctx = fakeCtx()
  apply(ctx, {
    url: 'http://tower.test',
    projMap: {},
    chatType: 'my/transcript',
    fullContextWorkspaces: '/home/ystyle/notes = none',
  })
  const calls = await withStubbedFetch(async () => {
    ctx.emit('session/event', fullCtxSession, userEvent('hi'))
    await settled()
  })
  assert.equal(calls[0].body.params.arguments.type, 'my/transcript')
})

test('the mount log names both types', async () => {
  const messages = []
  const original = console.log
  console.log = (message) => messages.push(String(message))
  const ctx = fakeCtx()
  try {
    apply(ctx, { url: 'http://tower.test', type: 'a/one', chatType: 'a/two' })
  } finally {
    console.log = original
  }
  assert.ok(messages.some((line) => line.includes('type=a/one') && line.includes('chat=a/two')))
})

// ---------------------------------------------------------------------------
// The bootstrap handle
//
// The type self-heal runs off the mount, so it outlives `apply()`. Cordis
// treats a promise *returned* by a plugin body as part of loading (`fiber.await()`
// waits on it, and the host boot waits on the fiber), so handing the bootstrap
// back would make a slow tower delay the mount — the one thing the
// fire-and-forget exists to prevent. These tests pin both halves: the mount
// stays non-blocking, and the work it leaves behind stays observable.
// ---------------------------------------------------------------------------

test('apply does not hand the type bootstrap back to the host', async () => {
  const tower = withScriptedTower({ 'mem/type_create': okBody() })
  const ctx = fakeCtx()
  let returned
  try {
    returned = applyPlugin(ctx, { url: 'http://tower.test' })
    // A returned promise is awaited by Cordis as part of loading the plugin.
    assert.equal(returned, undefined, 'a returned promise would make every mount wait for the tower')
    const handle = typesReadyOf(ctx)
    assert.equal(typeof handle?.then, 'function', 'the fire-and-forget work must still be awaitable from the context')
    // Awaiting the handle means the work is done — that is what makes it a
    // usable boundary instead of a sleep.
    await handle
  } finally {
    tower.restore()
  }
  const created = tower.calls
    .filter((call) => call.params.name === 'mem/type_create')
    .map((call) => call.params.arguments.name)
  assert.deepEqual(created, ['dsh/activity', 'dsh/chat'], 'awaiting the handle must mean the work is done')
})

test('a type bootstrap still in flight cannot land in the next tower', async () => {
  // The leak this pins: 忆时塔 type self-healing is issued from `ensureTypes()`
  // one type after another. A mount whose first request is still on the wire
  // (a real tower host resolves DNS for tens to hundreds of ms, then fails)
  // dispatches its *second* request after `apply()` returned — into whatever
  // `fetch` is installed by then. At a test boundary that is the *next* test's
  // scripted tower, which records it as one of its own: the failure mode is a
  // third `mem/type_create` appearing in a test that only mounted once.
  //
  // The two mounts use different hosts so a leaked request is identifiable by
  // where it went, not only by how many arrived.
  const slowDelayMs = 50
  const slow = []
  const original = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    slow.push({ url: String(url), body: JSON.parse(init.body) })
    await new Promise((resolve) => setTimeout(resolve, slowDelayMs))
    throw new TypeError('fetch failed')
  }
  const first = fakeCtx()
  apply(first, { url: 'http://first.test' })
  await Promise.resolve()
  assert.equal(slow.length, 1, 'the first request is on the wire and the second one is still owed')
  const handle = typesReadyOf(first)

  // ── the boundary ────────────────────────────────────────────────────────
  // With a handle, the leftover is waited out *here*, against a tower that
  // fails at once: the request still owed is dispatched while the next test's
  // stub is not installed, so it cannot be mistaken for that test's traffic.
  const strayed = await drainBootstraps()

  // ── the next test ───────────────────────────────────────────────────────
  const tower = withScriptedTower({ 'mem/type_create': okBody() })
  try {
    const second = fakeCtx()
    apply(second, { url: 'http://second.test', type: 'b/one', chatType: 'b/two' })
    const secondReady = typesReadyOf(second)
    if (secondReady !== null) {
      await secondReady
    } else {
      // Without a handle the only remaining option is to sleep — which is
      // exactly what makes this failure intermittent in the first place.
      await settled()
      await settled()
      await settled()
    }
  } finally {
    tower.restore()
  }

  const created = tower.calls
    .filter((call) => call.params.name === 'mem/type_create')
    .map((call) => call.params.arguments.name)
  assert.deepEqual(
    created,
    ['b/one', 'b/two'],
    "the second mount's tower must only see the second mount's own requests",
  )
  assert.deepEqual(
    [...new Set(tower.urls)],
    ['http://second.test/mcp'],
    'no request may reach a stub belonging to another mount',
  )
  if (handle !== null) {
    assert.deepEqual(
      strayed.map((call) => call.body.params.arguments.name),
      ['dsh/chat'],
      'the request the first mount still owed must be answered at the boundary, not by the next tower',
    )
    assert.deepEqual(
      [...new Set(strayed.map((call) => call.url))],
      ['http://first.test/mcp'],
      'the leftover must stay on its own host',
    )
  }
})
