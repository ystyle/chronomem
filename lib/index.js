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

import {
  appendRequest,
  compactEntry,
  errorEntry,
  goalEntry,
  isSubstantiveTurn,
  lifecycleEntry,
  mcpHeaders,
  mcpUrl,
  milestoneEntry,
  parseMcpBody,
  projFromCwd,
  resolveConfig,
  rpcFailure,
  textOfBlocks,
  titleEntry,
  turnEntry,
} from './pure.js'

export const name = 'dsh-mem-bridge'

const MAX_SESSIONS = 200
const RETRY_MAX = 5
const REQUEST_TIMEOUT_MS = 5000

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
  const cfg = resolveConfig(config, process.env)
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
          for (let attempt = 1; attempt <= RETRY_MAX; attempt += 1) {
            try {
              await append(item.entry, item.at)
              lastError = null
              break
            } catch (error) {
              lastError = error
              stats.attempts += 1
              if (attempt < RETRY_MAX) await sleep(250 * 2 ** (attempt - 1))
            }
          }
          queue.shift()
          if (lastError === null) {
            stats.written += 1
          } else {
            stats.failed += 1
            if (stats.failed === 1 || stats.failed % 50 === 0) {
              warn(`write failed after ${RETRY_MAX} attempts (${stats.failed} dropped so far): ${describeError(lastError)}`)
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
    enqueue(goalEntry(state.subject, {
      goalId: ref.id,
      revision: ref.revision,
      phase: goal === null ? 'cleared' : goal.phase,
      operation: change.operation,
      objective: goal === null ? undefined : leafString(goal, 'objective'),
      blocker: blocked,
      noteMax: cfg.goalNoteMax,
    }), undefined)
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

export default { name, apply }
