/**
 * dsh-mem-bridge — host half.
 *
 * A standing, profile-top-level plugin: it is an *untagged* listener, which
 * @deepseek-ai/dsh-scope admits globally, so this one instance observes every
 * agent's events (design doc §9.1). It turns those events into `{ payload, tags }`
 * entries (all decisions live in ./pure.js) and appends them to 忆时塔 over the
 * MCP streamable-HTTP endpoint.
 *
 * Guarantees:
 * - never blocks a turn: every write goes through an in-process queue, and a
 *   failure is logged, retried, then dropped (D6);
 * - never copies L0: only the final assistant text, the compaction summary dsh
 *   already produced, and event-borne scalars enter an entry;
 * - every contribution is a fiber effect, so stop/update/undefine removes it.
 */

import z from '@deepseek-ai/schemastery'

import {
  DISTILL_SYSTEM,
  appendRequest,
  buildDistillPrompt,
  callRequest,
  closeEntry,
  compactEntry,
  errorEntry,
  goalEntry,
  isRetryableWriteFailure,
  isSubstantiveTurn,
  lifecycleEntry,
  mcpHeaders,
  mcpUrl,
  milestoneEntry,
  parseDistillReply,
  parseMcpBody,
  projFromCwd,
  resolveConfig,
  resultText,
  rpcFailure,
  textOfBlocks,
  titleEntry,
  turnEntry,
  workflowEntry,
} from './pure.js'

export const name = 'dsh-mem-bridge'

/**
 * Config schema (design doc D16② / §282).
 *
 * Only the four fields a user actually needs to reach are `.volatile()`: the
 * settings form projects exactly the volatile fields, so everything else stays
 * a plain field reachable through the profile entry or `DSH_MEM_BRIDGE_*` env.
 * Keeping the tuning knobs off the form is deliberate — eighteen controls would
 * bury the four that matter.
 *
 * `token` is `.role('secret')`: the form reports presence instead of the value,
 * and the secret never round-trips to a client.
 *
 * A volatile field is a live reference: it must be read with `.get()` at each
 * use site, so a save in the settings form takes effect without re-mounting the
 * plugin (see `readVolatile` below and design doc §344).
 */
const Config = z.object({
  url: z.string().default('http://127.0.0.1:8900').volatile(),
  // No `default('')` on purpose. The settings form reports a secret as
  // "configured" from whether the resolved value is present at all, not from
  // its content, so an empty-string default would make every fresh install
  // claim a key it never had. Absence is the honest state; `resolveConfig`
  // turns it into '' for the writer, and `mcpHeaders` sends no Authorization
  // header for '' (`pure.js`).
  token: z.string().role('secret').volatile(),
  enabled: z.boolean().default(true).volatile(),
  distill: z.boolean().default(true).volatile(),
})

const MAX_SESSIONS = 200
const REQUEST_TIMEOUT_MS = 5000

/**
 * Unwrap one config field.
 *
 * A `.volatile()` field arrives as a live reference (`.get()`); a plain field
 * arrives as its value. `resolveConfig` in `./pure.js` stays value-based — it
 * has no dependency on schemastery and keeps its own unit tests — so the
 * unwrapping happens here, at the boundary.
 */
function readField(value) {
  if (value !== null && typeof value === 'object' && typeof value.get === 'function') {
    try {
      return value.get()
    } catch (_) {
      return undefined
    }
  }
  return value
}

/** Project the raw plugin config onto plain values for `resolveConfig`. */
function plainConfig(config) {
  if (config === null || typeof config !== 'object') return config
  const out = {}
  for (const key of Object.keys(config)) out[key] = readField(config[key])
  return out
}

/** Read a leaf string off a live object without copying or enumerating it. */
function leafString(owner, key) {
  try {
    const value = owner === null || owner === undefined ? undefined : owner[key]
    return typeof value === 'string' && value !== '' ? value : null
  } catch (_) {
    return null
  }
}

/** `session.id` (Session types it as the durable header id). */
function sessionIdOf(session) {
  return leafString(session, 'id')
}

/** `session.header.cwd` — the proj inference source (design doc §9.3). */
function sessionCwdOf(session) {
  try {
    const header = session === null || session === undefined ? undefined : session.header
    return leafString(header, 'cwd')
  } catch (_) {
    return null
  }
}

function agentIdOf(agent) {
  return leafString(agent, 'id')
}

function describeError(error) {
  if (error === null || error === undefined) return 'unknown error'
  if (typeof error === 'string') return error
  if (typeof error === 'object' && typeof error.message === 'string') return error.message
  return String(error)
}

export function apply(ctx, config) {
  const cfg = resolveConfig(plainConfig(config), process.env)
  const log = (message) => console.log(`[mem-bridge] ${message}`)
  const warn = (message) => console.error(`[mem-bridge] ${message}`)

  if (!cfg.enabled) {
    log('disabled (config.enabled=false or DSH_MEM_BRIDGE_ENABLE=false) — nothing will be recorded')
    return
  }

  const sessions = new Map()
  const queue = []
  const stats = { written: 0, dropped: 0, failed: 0, attempts: 0 }
  let stopping = false
  let flushing = null
  let rpcId = 0

  ctx.effect(() => () => {
    stopping = true
  })

  // ---------------------------------------------------------------- session state

  function ensureSession(id) {
    let state = sessions.get(id)
    if (state === undefined) {
      state = {
        subject: { session: id, agent: id, proj: null },
        turn: null,
        titleSeen: false,
        titleWasFallback: false,
        // Lifecycle bookkeeping (D17). dsh may announce the same session-start
        // more than once, and a restart announces every restored session — so
        // `open` is written once, and `resume` waits for real activity.
        wroteOpen: false,
        wroteResume: false,
        pendingResumeAt: null,
      }
      if (sessions.size >= MAX_SESSIONS) sessions.delete(sessions.keys().next().value)
      sessions.set(id, state)
    }
    return state
  }

  function sessionState(session) {
    const id = sessionIdOf(session)
    if (id === null) return null
    const state = ensureSession(id)
    const cwd = sessionCwdOf(session)
    if (state.subject.proj === null && cwd !== null) state.subject.proj = projFromCwd(cwd, cfg.projMap)
    return state
  }

  function stateOfAgent(agent) {
    const id = agentIdOf(agent)
    return id === null ? null : ensureSession(id)
  }

  // The Session object is not part of `agent/session-start`, so read cwd from the
  // store when it can already answer — otherwise the lifecycle entry would land
  // with no proj while its sibling turn entries carry one.
  function cwdFromStore(id) {
    try {
      const sessionsService = ctx.get('sessions')
      if (sessionsService === undefined || sessionsService === null) return null
      const session = sessionsService.get(id)
      return session === undefined || session === null ? null : sessionCwdOf(session)
    } catch (_) {
      return null
    }
  }

  // ---------------------------------------------------------------- writer (D6)

  const sleep = (ms) => new Promise((resolve) => {
    setTimeout(resolve, ms)
  })

  async function append(entry, at) {
    rpcId += 1
    const response = await fetch(mcpUrl(cfg.url), {
      method: 'POST',
      headers: mcpHeaders(cfg.token),
      body: JSON.stringify(appendRequest(rpcId, cfg.type, entry, at)),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })
    if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`)
    const failure = rpcFailure(parseMcpBody(await response.text()))
    if (failure !== null) throw new Error(failure)
  }

  /** One read-only tools/call against the tower; returns the tool's text result. */
  async function callTool(name, args) {
    rpcId += 1
    const response = await fetch(mcpUrl(cfg.url), {
      method: 'POST',
      headers: mcpHeaders(cfg.token),
      body: JSON.stringify(callRequest(rpcId, name, args)),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    })
    if (!response.ok) throw new Error(`HTTP ${response.status} ${response.statusText}`)
    const body = parseMcpBody(await response.text())
    const failure = rpcFailure(body)
    if (failure !== null) throw new Error(failure)
    return resultText(body.result)
  }

  /** The host's default model route, used when the bridge has no explicit one. */
  function readHostModel() {
    try {
      const service = ctx.get('agentDefaultModel')
      if (service === undefined || service === null) return null
      const selection = service.currentSelection()
      if (selection === null || typeof selection !== 'object') return null
      const provider = typeof selection.provider === 'string' ? selection.provider : ''
      const model = typeof selection.model === 'string' ? selection.model : ''
      return provider !== '' && model !== '' ? { provider, model } : null
    } catch (_) {
      return null
    }
  }

  // ---------------------------------------------------------------- L2b close (M3)

  // 护栏（§3.3）：每会话收口最多 1 次 LLM 蒸馏；每日上限；可整体关闭。
  // 关闭或失败时退化为骨架 close 条目，不留空洞。
  const closedSessions = new Set()
  let distillDay = ''
  let distillCountToday = 0

  function takeDistillBudget() {
    const today = new Date().toISOString().slice(0, 10)
    if (today !== distillDay) {
      distillDay = today
      distillCountToday = 0
    }
    if (distillCountToday >= cfg.maxDaily) return false
    distillCountToday += 1
    return true
  }

  /** One-shot distillation over the tower's own timeline (D11: never re-read the session). */
  async function distillClose(state, goalId, objective) {
    const llm = ctx.get('llm')
    if (llm === undefined || llm === null) return null
    const host = readHostModel()
    const provider = cfg.distillProvider !== '' ? cfg.distillProvider : (host === null ? '' : host.provider)
    const model = cfg.distillModel !== '' ? cfg.distillModel : (host === null ? '' : host.model)
    if (provider === '' || model === '') return null

    const timeline = await callTool('mem/query', {
      type: cfg.type,
      tag: `session=${state.subject.session}`,
      limit: cfg.tailN,
    })

    const messages = [{
      id: `mem-bridge-close-${Date.now()}`,
      role: 'user',
      content: [{ type: 'text', text: buildDistillPrompt({ goalId, objective, timeline }) }],
      source: { kind: 'plugin', plugin: 'dsh-mem-bridge' },
    }]

    let text = ''
    for await (const chunk of llm.stream({ provider, model, messages, system: DISTILL_SYSTEM })) {
      if (chunk === null || typeof chunk !== 'object') continue
      if (chunk.type === 'text-delta' && typeof chunk.text === 'string') text += chunk.text
      if (chunk.type === 'finish') {
        const kind = chunk.reason !== null && typeof chunk.reason === 'object' ? chunk.reason.kind : undefined
        if (kind === 'error' || kind === 'aborted') return null
      }
    }
    const parsed = parseDistillReply(text)
    if (parsed.outcome === '' && parsed.next === '' && parsed.note === '') return null
    return parsed
  }

  /**
   * Record the close account for one completed goal.
   *
   * Called from the goal-complete path; runs off the event dispatch so a slow
   * model call can never delay dsh. Any failure degrades to the skeleton entry.
   */
  async function maybeClose(state, goalId, objective) {
    const sessionId = state.subject.session
    let distilled = null
    const alreadyClosed = closedSessions.has(sessionId)
    if (cfg.distill && !alreadyClosed && takeDistillBudget()) {
      try {
        distilled = await distillClose(state, goalId, objective)
      } catch (error) {
        warn(`close distillation failed, using skeleton: ${describeError(error)}`)
      }
    }
    closedSessions.add(sessionId)

    if (distilled !== null) {
      enqueue(closeEntry(state.subject, {
        goalId,
        objective,
        outcome: distilled.outcome,
        next: distilled.next,
        note: distilled.note,
        distilled: true,
      }), undefined)
      return
    }
    enqueue(closeEntry(state.subject, {
      goalId,
      objective,
      outcome: '',
      next: '',
      note: `骨架收口（未蒸馏）：目标已完成${objective === undefined || objective === '' ? '' : ` — ${objective}`}`,
      distilled: false,
    }), undefined)
  }

  function enqueue(entry, at) {
    if (entry === null || entry === undefined || stopping) return
    queue.push({ entry, at: typeof at === 'number' ? at : Date.now() })
    if (queue.length > cfg.queueMax) {
      queue.shift()
      stats.dropped += 1
      if (stats.dropped === 1 || stats.dropped % 100 === 0) {
        warn(`queue full (${cfg.queueMax}): dropped ${stats.dropped} oldest entry(ies)`)
      }
    }
    void drain()
  }

  function drain() {
    if (flushing !== null) return flushing
    flushing = (async () => {
      try {
        while (!stopping && queue.length > 0) {
          const item = queue[0]
          let lastError = null
          const retryMax = cfg.retryMax >= 1 ? Math.trunc(cfg.retryMax) : 1
          for (let attempt = 1; attempt <= retryMax; attempt += 1) {
            try {
              await append(item.entry, item.at)
              lastError = null
              break
            } catch (error) {
              lastError = error
              stats.attempts += 1
              // Only a provably-undelivered request may be repeated: 忆时塔 can
              // apply an append and then never answer, and retrying that writes
              // the entry twice (see isRetryableWriteFailure).
              if (attempt >= retryMax || !isRetryableWriteFailure(error)) break
              if (cfg.retryBackoffMs > 0) await sleep(cfg.retryBackoffMs * 2 ** (attempt - 1))
            }
          }
          queue.shift()
          if (lastError === null) {
            stats.written += 1
          } else {
            stats.failed += 1
            if (stats.failed === 1 || stats.failed % 50 === 0) {
              warn(`write failed after ${retryMax} attempts (${stats.failed} dropped so far): ${describeError(lastError)}`)
            }
          }
        }
      } catch (error) {
        warn(`unexpected writer failure: ${describeError(error)}`)
      } finally {
        flushing = null
      }
    })()
    return flushing
  }

  // ---------------------------------------------------------------- turn bookkeeping

  function turnOf(state, turn) {
    if (state.turn === null || state.turn.turn !== turn) {
      state.turn = { turn, lastText: '', toolCalls: 0, toolErrors: 0 }
    }
    return state.turn
  }

  // ---------------------------------------------------------------- event wiring

  ctx.on('session/event', (session, event) => {
    if (event === null || event === undefined || typeof event.type !== 'string') return
    const state = sessionState(session)
    if (state === null) return
    const data = event.data !== null && typeof event.data === 'object' ? event.data : {}
    const at = typeof event.time === 'number' ? event.time : undefined

    // A deferred `resume` is flushed by this session's first real event: a
    // session that a restart merely restored and nobody touched stays out of the
    // tower (D17). The entry keeps the resume's own timestamp, not this one.
    if (state.pendingResumeAt !== null) {
      const resumeAt = state.pendingResumeAt
      state.pendingResumeAt = null
      state.wroteResume = true
      enqueue(lifecycleEntry(state.subject, 'resume'), resumeAt)
    }

    switch (event.type) {
      case 'assistant/message': {
        if (typeof data.turn !== 'number') return
        // Keep the LAST text-bearing assistant message of the turn. The probe
        // (§9.3) showed intermediate steps are usually textless tool-call
        // messages or short narration, while the turn's last message is the
        // final answer.
        const message = data.message
        const text = textOfBlocks(message === null || message === undefined ? null : message.content)
        if (text !== '') turnOf(state, data.turn).lastText = text
        return
      }
      case 'tool/call': {
        if (typeof data.turn !== 'number') return
        turnOf(state, data.turn).toolCalls += 1
        return
      }
      case 'tool/result': {
        if (typeof data.turn !== 'number') return
        if (data.error !== undefined && data.error !== null) turnOf(state, data.turn).toolErrors += 1
        return
      }
      case 'turn/end': {
        const reason = data.reason !== null && typeof data.reason === 'object' ? data.reason.kind : undefined
        const turn = typeof data.turn === 'number' ? data.turn : null
        if (turn === null) return
        const acc = state.turn !== null && state.turn.turn === turn ? state.turn : turnOf(state, turn)
        state.turn = null
        if (reason !== 'completed') return
        if (!isSubstantiveTurn({ toolCalls: acc.toolCalls, text: acc.lastText }, cfg)) return
        enqueue(turnEntry(state.subject, {
          turn,
          text: acc.lastText,
          toolCalls: acc.toolCalls,
          toolErrors: acc.toolErrors,
          noteMax: cfg.turnNoteMax,
        }), at)
        return
      }
      case 'session/title': {
        // The fallback title lands first, the LLM title second: keep the fallback
        // only while nothing better has arrived, so a session that never gets an
        // LLM title still ends up with one.
        const title = typeof data.title === 'string' ? data.title : ''
        if (title === '') return
        const sourceKind = data.source !== null && typeof data.source === 'object' ? data.source.kind : undefined
        const isFallback = sourceKind === 'fallback'
        if (isFallback && state.titleSeen) return
        state.titleSeen = true
        state.titleWasFallback = isFallback
        enqueue(titleEntry(state.subject, title, sourceKind), at)
        return
      }
      case 'compaction/summary': {
        // `compaction/prune` is tool-result pruning, not a semantic summary, so it
        // deliberately falls through to `default`.
        enqueue(compactEntry(state.subject, {
          compactionId: data.compactionId,
          summaryText: textOfBlocks(data.summary),
          shadowedRange: data.shadowedRange,
          shadowedTokenCount: data.shadowedTokenCount,
        }), at)
        return
      }
      default:
        return
    }
  })

  ctx.on('agent/session-start', (payload) => {
    if (payload === null || typeof payload !== 'object') return
    const state = stateOfAgent(payload.agent)
    if (state === null) return
    if (state.subject.proj === null) {
      const cwd = cwdFromStore(state.subject.session)
      if (cwd !== null) state.subject.proj = projFromCwd(cwd, cfg.projMap)
    }
    if (payload.source === 'resume') {
      // Defer: see the flush above. Only the first resume of a session is kept.
      if (!state.wroteResume && state.pendingResumeAt === null) state.pendingResumeAt = Date.now()
      return
    }
    if (state.wroteOpen) return
    state.wroteOpen = true
    enqueue(lifecycleEntry(state.subject, payload.source), undefined)
  })

  ctx.on('goal/changed', (payload) => {
    if (payload === null || typeof payload !== 'object') return
    const state = stateOfAgent(payload.agent)
    const change = payload.change
    if (state === null || change === null || typeof change !== 'object') return
    const ref = change.ref !== null && typeof change.ref === 'object' ? change.ref : {}
    const goal = change.goal !== null && typeof change.goal === 'object' ? change.goal : null
    const blocked = goal !== null && goal.blockedReason !== null && typeof goal.blockedReason === 'object'
      ? (leafString(goal.blockedReason, 'message') ?? leafString(goal.blockedReason, 'code'))
      : null
    const objective = goal === null ? undefined : leafString(goal, 'objective')
    enqueue(goalEntry(state.subject, {
      goalId: ref.id,
      revision: ref.revision,
      phase: goal === null ? 'cleared' : goal.phase,
      operation: change.operation,
      objective,
      blocker: blocked,
      noteMax: cfg.goalNoteMax,
    }), undefined)
    // L2b：目标完成 → 出聚合账（在事件分发之外跑，慢模型调用绝不阻塞 dsh）
    if (change.operation === 'complete') {
      const goalId = typeof ref.id === 'string' ? ref.id : ''
      void maybeClose(state, goalId, objective ?? '')
    }
  })

  ctx.on('subagent/end', (info) => {
    if (info === null || typeof info !== 'object') return
    const childId = leafString(info, 'id')
    const state = childId === null ? null : ensureSession(childId)
    if (state === null) return
    enqueue(milestoneEntry({
      session: childId,
      agent: childId,
      proj: state.subject.proj,
      role: 'subagent',
    }, {
      runId: info.runId,
      stopReason: info.stopReason,
      text: textOfBlocks(info.lastAssistantMessage),
      noteMax: cfg.milestoneNoteMax,
    }), undefined)
  })

  // workflow/end 只带事实（run 身份 / stopReason / agentsStarted，**明确不含结果值**）——
  // 子代理各自的 subagent/end 里程碑才是实质内容，这里记一条可检索的骨架。
  ctx.on('workflow/end', (info, result) => {
    if (info === null || typeof info !== 'object') return
    const runId = leafString(info, 'id')
    const meta = info.meta !== null && typeof info.meta === 'object' ? info.meta : null
    const outcome = result !== null && typeof result === 'object' ? result : null
    enqueue(workflowEntry({ session: null, agent: null, proj: null }, {
      runId,
      name: meta === null ? null : leafString(meta, 'name'),
      description: meta === null ? null : leafString(meta, 'description'),
      stopReason: outcome === null ? null : outcome.stopReason,
      agentsStarted: outcome === null ? null : outcome.agentsStarted,
      error: outcome === null ? null : leafString(outcome, 'error'),
    }), undefined)
  })

  ctx.on('agent/error', (payload) => {
    if (payload === null || typeof payload !== 'object') return
    const state = stateOfAgent(payload.agent)
    if (state === null) return
    const error = payload.error !== null && typeof payload.error === 'object' ? payload.error : {}
    enqueue(errorEntry(state.subject, {
      turn: payload.turn,
      step: payload.step,
      code: leafString(error, 'code') ?? leafString(error, 'name'),
    }), undefined)
  })

  log(`enabled → ${mcpUrl(cfg.url)} (type=${cfg.type})`)
}

export { Config }
export default { name, Config, apply }
