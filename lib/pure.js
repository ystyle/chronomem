/**
 * dsh-mem-bridge — pure logic layer.
 *
 * Everything here is a plain function over JSON values: no Cordis, no network,
 * no timers. The plugin half (`lib/index.js`) owns lifecycle and I/O; this half
 * owns the decisions worth testing — what counts as a turn, how text is
 * clipped, how `proj` is inferred, and the exact `{ payload, tags }` shape sent
 * to 忆时塔.
 *
 * Design of record: docs/plans/2026-09-05-dsh-session-memory.md (v4, §2–§3).
 */

/** 忆时塔 type names (namespace `dsh/` isolates this source domain). */
export const TYPE_ACTIVITY = 'dsh/activity'
export const TYPE_LESSON = 'dsh/lesson'

/** Every `kind` tag value written into `dsh/activity`. */
export const KIND = {
  open: 'open',
  resume: 'resume',
  title: 'title',
  turn: 'turn',
  compact: 'compact',
  goal: 'goal',
  milestone: 'milestone',
  close: 'close',
  error: 'error',
}

/**
 * Clip one over-long text to `max` characters, keeping both ends.
 *
 * The plan calls for head+tail retention: a long final answer usually carries
 * its conclusion at the end, and a compaction summary carries its subject at
 * the beginning. The inserted marker reports how much was dropped so a reader
 * never mistakes a clipped note for a complete one.
 *
 * @param {unknown} text raw text.
 * @param {number} max maximum characters; `<= 0` means "no limit".
 * @returns {string} the text, or a head/marker/tail rendering of it.
 */
export function clipText(text, max) {
  if (typeof text !== 'string') return ''
  if (!Number.isFinite(max) || max <= 0 || text.length <= max) return text
  const head = Math.floor(max * 0.6)
  const tail = max - head
  const omitted = text.length - head - tail
  return text.slice(0, head) + `\n…[省略 ${omitted} 字]…\n` + text.slice(text.length - tail)
}

/** First line of a text, clipped — used for the one-line `title` of an entry. */
export function firstLine(text, max) {
  if (typeof text !== 'string') return ''
  const nl = text.indexOf('\n')
  const line = (nl >= 0 ? text.slice(0, nl) : text).trim()
  return clipText(line, max)
}

/**
 * Concatenate the `text` blocks of a ContentBlock[].
 *
 * Only `text` blocks count: `reasoning` is scratch work, and tool-call/result
 * blocks are the L0 layer the bridge must never copy into the tower.
 *
 * @param {unknown} blocks a ContentBlock[] as delivered on session events.
 * @returns {string} the concatenated text, `'\n'`-joined.
 */
export function textOfBlocks(blocks) {
  if (!Array.isArray(blocks)) return ''
  const parts = []
  for (const block of blocks) {
    if (block !== null && typeof block === 'object' && block.type === 'text' && typeof block.text === 'string') {
      parts.push(block.text)
    }
  }
  return parts.join('\n')
}

/** Block type names of a ContentBlock[] (diagnostics only). */
export function blockKinds(blocks) {
  if (!Array.isArray(blocks)) return []
  const out = []
  for (const block of blocks) {
    if (block !== null && typeof block === 'object' && typeof block.type === 'string') out.push(block.type)
  }
  return out
}

/**
 * Decide the `proj` tag for one session from its cwd.
 *
 * Longest-prefix wins in the mapping table so a nested path can be addressed
 * exactly; otherwise the cwd's own directory name is used, and an unknown or
 * absent cwd yields `null` (the tower buckets that as 未分组).
 *
 * @param {unknown} cwd absolute session cwd.
 * @param {Record<string, string> | undefined} map path-prefix → proj overrides.
 * @returns {string | null} the proj tag value, or `null` when undecidable.
 */
export function projFromCwd(cwd, map) {
  if (typeof cwd !== 'string' || cwd === '') return null
  if (map !== null && typeof map === 'object') {
    let best = null
    let bestLen = -1
    for (const key of Object.keys(map)) {
      if (typeof key !== 'string' || key === '') continue
      const prefix = key.endsWith('/') ? key : key + '/'
      if ((cwd === key || cwd.startsWith(prefix)) && key.length > bestLen) {
        bestLen = key.length
        best = map[key]
      }
    }
    if (typeof best === 'string' && best !== '') return best
  }
  const trimmed = cwd.replace(/\/+$/, '')
  const slash = trimmed.lastIndexOf('/')
  const base = slash >= 0 ? trimmed.slice(slash + 1) : trimmed
  return base === '' ? null : base
}

/** Trim a tag map: drop `null`/`undefined`/empty values so the tower stores only real keys. */
export function compactTags(tags) {
  const out = {}
  for (const key of Object.keys(tags)) {
    const value = tags[key]
    if (value === null || value === undefined) continue
    const text = String(value)
    if (text === '') continue
    out[key] = text
  }
  return out
}

/** Shared tag base for one activity entry. */
function baseTags(kind, subject) {
  return compactTags({
    kind,
    session: subject.session,
    agent: subject.agent,
    proj: subject.proj,
    branch: subject.branch,
    role: subject.role,
  })
}

/** An entry as `{ payload, tags }`, ready for `mem/append`. */
function entry(kind, subject, payload) {
  return { payload, tags: baseTags(kind, subject) }
}

/** `kind=open|resume` — session lifecycle began. */
export function lifecycleEntry(subject, source) {
  const kind = source === 'resume' ? KIND.resume : KIND.open
  return entry(kind, subject, {
    title: '',
    note: `会话开始（source=${source}）`,
  })
}

/** `kind=title` — the durable session title, which only exists after the session starts. */
export function titleEntry(subject, title, source) {
  return entry(KIND.title, subject, {
    title: clipText(typeof title === 'string' ? title : '', 120),
    note: `source=${source === undefined || source === null ? 'unknown' : String(source)}`,
  })
}

/**
 * `kind=turn` — one completed turn's final answer.
 *
 * The caller must pass the LAST `assistant/message` before `turn/end`
 * (probe-verified: that one is the final answer; the intermediate steps are
 * tool-call messages with no text, or short process narration).
 */
export function turnEntry(subject, { turn, text, toolCalls, toolErrors, noteMax }) {
  const stats = `tools=${count(toolCalls)}${count(toolErrors) > 0 ? ` errors=${count(toolErrors)}` : ''}`
  return {
    payload: {
      title: firstLine(text, 120),
      note: clipText(text, noteMax),
      stats,
    },
    tags: compactTags(Object.assign(baseTags(KIND.turn, subject), { turn: turn })),
  }
}

/** `kind=compact` — the compaction summary dsh already paid an LLM for. */
export function compactEntry(subject, { compactionId, summaryText, shadowedRange, shadowedTokenCount }) {
  const span = spanText(shadowedRange)
  return {
    payload: {
      title: span === '' ? '上下文压缩' : `上下文压缩 span ${span}`,
      note: clipText(summaryText, 16000),
      stats: `shadowedTokenCount=${count(shadowedTokenCount)}`,
    },
    tags: compactTags(Object.assign(baseTags(KIND.compact, subject), { span, cid: compactionId })),
  }
}

/** `kind=goal` — one goal state transition. */
export function goalEntry(subject, { goalId, revision, phase, operation, objective, progress, blocker, noteMax }) {
  const noteParts = [`operation=${operation}`]
  if (typeof progress === 'string' && progress !== '') noteParts.push(`progress=${progress}`)
  if (typeof blocker === 'string' && blocker !== '') noteParts.push(`blocker=${blocker}`)
  return {
    payload: {
      title: clipText(typeof objective === 'string' ? objective : '', 120),
      note: clipText(noteParts.join('\n'), noteMax),
      ...(typeof progress === 'string' && progress !== '' ? { progress: clipText(progress, noteMax) } : {}),
      ...(typeof blocker === 'string' && blocker !== '' ? { blocker: clipText(blocker, 1000) } : {}),
    },
    tags: compactTags(Object.assign(baseTags(KIND.goal, subject), {
      goal: goalId,
      rev: revision,
      phase,
    })),
  }
}

/** `kind=milestone` — a subagent (or workflow) settled; its last reply is the pre-distilled result. */
export function milestoneEntry(subject, { runId, stopReason, text, noteMax }) {
  return {
    payload: {
      title: `子代理结束（${stopReason === undefined || stopReason === null ? 'unknown' : String(stopReason)}）`,
      note: clipText(text, noteMax),
      outcome: stopReason === undefined || stopReason === null ? '' : String(stopReason),
    },
    tags: compactTags(Object.assign(baseTags(KIND.milestone, subject), { run: runId })),
  }
}

/** `kind=error` — facts only; never the error body or a stack. */
export function errorEntry(subject, { turn, step, code }) {
  return {
    payload: {
      title: `轮 ${count(turn)} 步骤 ${count(step)} 出错`,
      note: `code=${code === undefined || code === null ? 'unknown' : String(code)}`,
      blocker: code === undefined || code === null ? '' : String(code),
    },
    tags: compactTags(Object.assign(baseTags(KIND.error, subject), { turn, step })),
  }
}

/** `kind=close` — the L2b aggregate account for one goal completing. */
export function closeEntry(subject, { goalId, outcome, next, note }) {
  return {
    payload: {
      title: '目标收口',
      note: clipText(note, 4000),
      outcome: clipText(outcome, 2000),
      next: clipText(next, 1000),
    },
    tags: compactTags(Object.assign(baseTags(KIND.close, subject), { goal: goalId })),
  }
}

function count(value) {
  return typeof value === 'number' && Number.isFinite(value) ? Math.trunc(value) : 0
}

function spanText(range) {
  if (range === null || typeof range !== 'object') return ''
  const start = range.start
  const end = range.end
  if (typeof start !== 'number' || typeof end !== 'number') return ''
  return `${Math.trunc(start)}..${Math.trunc(end)}`
}

/** First non-empty string of the candidates. */
function pick(...candidates) {
  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate !== '') return candidate
  }
  return ''
}

function pickBool(value, fallback) {
  if (typeof value === 'boolean') return value
  if (value === 'true') return true
  if (value === 'false') return false
  return fallback
}

function pickNumber(value, fallback) {
  if (typeof value === 'number' && Number.isFinite(value)) return value
  if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) return Number(value)
  return fallback
}

/**
 * Resolve effective configuration: row `config` first, `DSH_MEM_BRIDGE_*` env as fallback, then defaults.
 *
 * @param {unknown} config the plugin row's `config` object.
 * @param {unknown} env environment variables (defaults to `process.env`).
 */
export function resolveConfig(config, env) {
  const c = config !== null && typeof config === 'object' ? config : {}
  const e = env !== null && typeof env === 'object' ? env : {}
  const projMap = c.projMap !== null && typeof c.projMap === 'object' ? c.projMap : {}
  return {
    url: pick(c.url, e.DSH_MEM_BRIDGE_URL, 'http://127.0.0.1:8900'),
    token: pick(c.token, e.DSH_MEM_BRIDGE_TOKEN, ''),
    enabled: pickBool(c.enabled ?? e.DSH_MEM_BRIDGE_ENABLE, true),
    type: pick(c.type, e.DSH_MEM_BRIDGE_TYPE, TYPE_ACTIVITY),
    queueMax: pickNumber(c.queueMax ?? e.DSH_MEM_BRIDGE_QUEUE_MAX, 500),
    retryMax: pickNumber(c.retryMax ?? e.DSH_MEM_BRIDGE_RETRY_MAX, 5),
    retryBackoffMs: pickNumber(c.retryBackoffMs ?? e.DSH_MEM_BRIDGE_RETRY_BACKOFF_MS, 250),
    turnNoteMax: pickNumber(c.turnNoteMax ?? e.DSH_MEM_BRIDGE_TURN_NOTE_MAX, 6000),
    compactNoteMax: pickNumber(c.compactNoteMax ?? e.DSH_MEM_BRIDGE_COMPACT_NOTE_MAX, 16000),
    milestoneNoteMax: pickNumber(c.milestoneNoteMax ?? e.DSH_MEM_BRIDGE_MILESTONE_NOTE_MAX, 2000),
    goalNoteMax: pickNumber(c.goalNoteMax ?? e.DSH_MEM_BRIDGE_GOAL_NOTE_MAX, 2000),
    turnMinTools: pickNumber(c.turnMinTools ?? e.DSH_MEM_BRIDGE_TURN_MIN_TOOLS, 1),
    turnMinLen: pickNumber(c.turnMinLen ?? e.DSH_MEM_BRIDGE_TURN_MIN_LEN, 120),
    projMap,
  }
}

/**
 * D3/D10: does a completed turn deserve an entry?
 *
 * 「或」semantics — a turn that did work OR said something substantial counts;
 * a bare acknowledgement counts as neither.
 */
export function isSubstantiveTurn({ toolCalls, text }, { turnMinTools, turnMinLen }) {
  if (count(toolCalls) >= turnMinTools && turnMinTools > 0) return true
  if (typeof text === 'string' && text.length >= turnMinLen && turnMinLen > 0) return true
  // Both thresholds disabled => record everything (documented full-capture mode).
  return turnMinTools <= 0 && turnMinLen <= 0
}

/** A JSON-RPC `tools/call` request for 忆时塔's streamable-HTTP MCP endpoint. */
export function appendRequest(id, type, entryValue, ts) {
  const args = { type, payload: entryValue.payload, tags: entryValue.tags }
  if (typeof ts === 'number' && Number.isFinite(ts)) args.ts = Math.trunc(ts)
  return {
    jsonrpc: '2.0',
    id,
    method: 'tools/call',
    params: { name: 'mem/append', arguments: args },
  }
}

/** A JSON-RPC `tools/call` request for a read-only tool (used by the integration self-test). */
export function callRequest(id, toolName, args) {
  return {
    jsonrpc: '2.0',
    id,
    method: 'tools/call',
    params: { name: toolName, arguments: args !== null && typeof args === 'object' ? args : {} },
  }
}

/** Headers for the chronomem MCP endpoint, including the optional Bearer token. */
export function mcpHeaders(token) {
  const headers = {
    'content-type': 'application/json',
    accept: 'application/json, text/event-stream',
  }
  if (typeof token === 'string' && token !== '') headers.authorization = `Bearer ${token}`
  return headers
}

/** The MCP tools/call URL for a base like `http://127.0.0.1:8900`. */
export function mcpUrl(base) {
  const trimmed = typeof base === 'string' ? base.replace(/\/+$/, '') : ''
  return (trimmed === '' ? 'http://127.0.0.1:8900' : trimmed) + '/mcp'
}

/** Concatenate the text blocks of a tools/call result. */
export function resultText(result) {
  if (result === null || typeof result !== 'object') return ''
  return textOfBlocks(result.content)
}

/**
 * Normalise one MCP HTTP body into a single JSON-RPC response object.
 *
 * The streamable-HTTP transport may answer either a plain JSON body or an SSE
 * frame stream. Silently mis-parsing that shape is the classic way a writer
 * "succeeds" while writing nothing, so both shapes are handled here and tested.
 *
 * @param {unknown} text raw response body.
 * @returns {object | null} the last complete JSON-RPC message, or `null`.
 */
export function parseMcpBody(text) {
  if (typeof text !== 'string') return null
  const trimmed = text.trim()
  if (trimmed === '') return null
  try {
    const parsed = JSON.parse(trimmed)
    return parsed !== null && typeof parsed === 'object' ? parsed : null
  } catch (_) {
    // Not a single JSON document — fall through to SSE frame scanning.
  }
  let last = null
  for (const line of trimmed.split(/\r?\n/)) {
    const match = /^data:\s*(.*)$/.exec(line)
    if (match === null) continue
    const payload = match[1].trim()
    if (payload === '' || payload === '[DONE]') continue
    try {
      const parsed = JSON.parse(payload)
      if (parsed !== null && typeof parsed === 'object') last = parsed
    } catch (_) {
      // A partial frame is not fatal: keep scanning for a complete one.
    }
  }
  return last
}

/**
 * Describe why a parsed JSON-RPC response did not succeed.
 *
 * @returns {string | null} a diagnostic, or `null` when the call succeeded.
 */
export function rpcFailure(body) {
  if (body === null || body === undefined) return 'empty response body'
  if (typeof body !== 'object') return 'unexpected response shape'
  if (body.error !== null && typeof body.error === 'object') {
    const code = body.error.code === undefined || body.error.code === null ? '' : ` ${body.error.code}`
    const message = typeof body.error.message === 'string' ? `: ${body.error.message}` : ''
    return `JSON-RPC error${code}${message}`
  }
  const result = body.result
  if (result !== null && typeof result === 'object' && result.isError === true) {
    const text = resultText(result)
    return text === '' ? 'tool returned isError' : `tool error: ${text}`
  }
  return null
}
