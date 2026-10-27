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
/**
 * Conversation transcript type, used only by full-context workspaces.
 *
 * A separate type from `dsh/activity` on purpose. `dsh/activity` is a
 * *low-frequency* operational timeline — session lifecycle, one final reply per
 * turn, goal state changes — and its `[day, week]` levels are sized for that.
 * A transcript is the opposite: every message of every exchange, so it wants
 * sub-hour windows while a day is in progress. Mixing them would make one
 * type's levels wrong for half its contents, and `levels` cannot be changed
 * after creation (`mem/type_update` refuses it), so the split has to be
 * decided up front.
 *
 * `1h → day → week` rather than the default five-link chain: a chat message
 * arrives every few minutes, so a 10-minute bucket holds nothing worth a
 * separate layer, while hour-level recall ("what did we discuss this
 * afternoon") is the useful-resolution unit.
 */
export const TYPE_CHAT = 'dsh/chat'

/** Type metadata the bridge asks 忆时塔 to create on first write. */
export function typeSpecs(cfg) {
  return [
    {
      name: cfg.type,
      description: 'dsh 会话活动时间线：会话生命周期（open/resume）、标题、轮次台账、上下文压缩、目标状态机、子代理里程碑与错误；纯自动账本，供 day/week 总结与按 session 回想。',
      levels: ['day', 'week'],
      autoSummarize: true,
      summaryGroupBy: ['proj'],
    },
    {
      name: cfg.chatType,
      description: 'dsh 对话历史：全上下文工作区里逐条记录的真人输入、assistant 回复与工具调用（工具按工作区配置的级别决定存多少）；供按小时/天/周回想一次具体交谈。',
      levels: ['1h', 'day', 'week'],
      autoSummarize: true,
      summaryGroupBy: ['proj'],
    },
  ]
}

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
  user: 'user',
  say: 'say',
  tool: 'tool',
}

/**
 * How much of a full-context session's tool traffic is recorded.
 *
 * `none` — no tool entries at all (a chat session: the tools are an artefact of
 * the harness, not part of what was said);
 * `names` — one entry per call carrying only the tool name and its error flag;
 * `full` — the call's arguments and the result text as well.
 *
 * Measured on a real 1265 KB session: tool arguments plus results were 87% of
 * every byte, against 0.34% for what the user actually typed. That ratio is why
 * this is a configurable enum rather than a boolean: "record everything" is
 * only meaningful once you have decided how much of the 87% you want.
 */
export const TOOL_MODES = ['none', 'names', 'full']

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
  // 标题只截尾部：首尾截断（clipText）会插「…[省略 N 字]…」标记，标题里读起来是坏的。
  if (!Number.isFinite(max) || max <= 0 || line.length <= max) return line
  return line.slice(0, max) + '…'
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

/**
 * One text-area line: `路径` or `路径 = 级别`.
 *
 * Paths contain no `=`, so the first one always separates the two halves; that
 * keeps a path with spaces working without quoting.
 */
const WORKSPACE_LINE = /^(?<path>[^=]+?)\s*(?:=\s*(?<level>.*))?$/u

/** The level a line with no explicit level takes: record tool names, not their bodies. */
export const DEFAULT_WORKSPACE_LEVEL = 'names'

/**
 * Parse the full-context workspace list out of one text-area value.
 *
 * One workspace per line, either `路径` or `路径 = 级别`; blank lines and `#`
 * comments are dropped; entries are trimmed and de-duplicated on path in
 * first-seen order. An entry is either an absolute path (matched as a path
 * prefix) or a bare directory name (matched against the cwd's last segment) —
 * see {@link matchesWorkspace}.
 *
 * The result is the object array the config schema declares, so this is both
 * what the settings page writes and what `resolveConfig` normalises:
 *
 * ```
 * /home/me/notes               → { path: '/home/me/notes', level: 'names' }
 * /home/me/notes = full        → { path: '/home/me/notes', level: 'full' }
 * journal = none               → { path: 'journal', level: 'none' }
 * ```
 *
 * An unrecognised level is dropped to the default rather than rejected: the
 * settings form refuses to save when {@link parseWorkspaceListStrict} returns
 * `undefined`, but the host parser still has to survive a hand-edited
 * `cordis.patch.yml`, and losing a whole workspace over a typo would be worse
 * than recording one level off.
 *
 * @param {unknown} text the text-area value, or an already-structured array.
 * @returns {{path: string, level: string}[]} the entries, in input order.
 */
export function parseWorkspaceList(text) {
  if (Array.isArray(text)) return normaliseWorkspaceArray(text)
  return parseWorkspaceText(text, false)
}

/**
 * Same parse, but report an invalid level instead of defaulting it.
 *
 * The settings form uses this so a typo blocks the save (the shared form model
 * treats an `undefined` parse as invalid) instead of silently writing `names`.
 *
 * @param {unknown} text the text-area value.
 * @returns {{path: string, level: string}[] | undefined} the entries, or
 *   `undefined` when a level is not one of {@link TOOL_MODES}.
 */
export function parseWorkspaceListStrict(text) {
  if (Array.isArray(text)) {
    const rows = normaliseWorkspaceArray(text)
    // normaliseWorkspaceArray defaults bad levels, so inspect the raw input too.
    for (const row of text) {
      if (row === null || typeof row !== 'object') continue
      if (typeof row.level === 'string' && row.level !== '' && !TOOL_MODES.includes(row.level)) return undefined
    }
    return rows
  }
  return parseWorkspaceText(text, true)
}

/**
 * Parse one text-area value.
 *
 * @param {unknown} text the text-area value.
 * @param {boolean} strict whether an unknown level returns `undefined`.
 * @returns {{path: string, level: string}[] | undefined} the rows.
 */
function parseWorkspaceText(text, strict) {
  if (typeof text !== 'string' || text === '') return []
  const out = []
  const seen = new Set()
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line === '' || line.startsWith('#')) continue
    const match = WORKSPACE_LINE.exec(line)
    if (match === null) continue
    const path = normaliseWorkspacePath(match.groups.path)
    if (path === '') continue
    const levelText = match.groups.level === undefined ? '' : match.groups.level.trim()
    if (levelText !== '' && !TOOL_MODES.includes(levelText)) {
      if (strict) return undefined
      if (seen.has(path)) continue
      seen.add(path)
      out.push({ path, level: DEFAULT_WORKSPACE_LEVEL })
      continue
    }
    const level = levelText === '' ? DEFAULT_WORKSPACE_LEVEL : levelText
    if (seen.has(path)) continue
    seen.add(path)
    out.push({ path, level })
  }
  return out
}

/**
 * Render the object array back into its text-area form, one `路径 = 级别` per line.
 *
 * The settings page formats through this, so a saved list always comes back
 * looking the way it was typed (including the explicit level).
 *
 * @param {unknown} rows the structured value.
 * @returns {string} the text-area value.
 */
export function formatWorkspaceList(rows) {
  if (!Array.isArray(rows)) return ''
  const lines = []
  for (const row of normaliseWorkspaceArray(rows)) lines.push(`${row.path} = ${row.level}`)
  return lines.join('\n')
}

/** Trim a hand-typed path: drop surrounding space and trailing slashes, keep a lone `/`. */
function normaliseWorkspacePath(value) {
  if (typeof value !== 'string') return ''
  const trimmed = value.trim()
  if (trimmed === '') return ''
  const stripped = trimmed.replace(/\/+$/, '')
  return stripped === '' ? '/' : stripped
}

/** Coerce a structured array (or anything else) into clean rows, defaulting bad levels. */
function normaliseWorkspaceArray(value) {
  if (!Array.isArray(value)) return []
  const out = []
  const seen = new Set()
  for (const row of value) {
    if (row === null || typeof row !== 'object') continue
    const path = normaliseWorkspacePath(row.path)
    if (path === '' || seen.has(path)) continue
    seen.add(path)
    const level = TOOL_MODES.includes(row.level) ? row.level : DEFAULT_WORKSPACE_LEVEL
    out.push({ path, level })
  }
  return out
}

/**
 * Does one cwd belong to the full-context workspace list?
 *
 * An absolute entry matches as a path prefix on a segment boundary, so
 * `/home/me/notes` covers `/home/me/notes` and `/home/me/notes/sub` but never
 * `/home/me/notes-old`. A bare entry matches the cwd's last segment exactly.
 * When several entries match, the longest path wins — that is what lets a broad
 * `notes = none` coexist with a narrow `notes/2026 = full`.
 *
 * @param {unknown} cwd absolute session cwd.
 * @returns {{path: string, level: string} | null} the winning entry.
 */
export function workspaceRuleFor(cwd, workspaces) {
  if (typeof cwd !== 'string' || cwd === '') return null
  if (!Array.isArray(workspaces) || workspaces.length === 0) return null
  const trimmed = cwd.replace(/\/+$/, '') || '/'
  const slash = trimmed.lastIndexOf('/')
  const base = slash >= 0 ? trimmed.slice(slash + 1) : trimmed
  let best = null
  let bestLen = -1
  for (const row of workspaces) {
    if (row === null || typeof row !== 'object') continue
    const path = typeof row.path === 'string' ? row.path : ''
    if (path === '') continue
    const level = TOOL_MODES.includes(row.level) ? row.level : DEFAULT_WORKSPACE_LEVEL
    let matched = false
    if (path.startsWith('/')) {
      matched = trimmed === path || trimmed.startsWith(path === '/' ? '/' : path + '/')
    } else {
      matched = path === base
    }
    if (!matched) continue
    // Longest wins; a bare name behaves like a one-segment path for this purpose.
    const length = path.length
    if (length > bestLen) {
      bestLen = length
      best = { path, level }
    }
  }
  return best
}

/** Does a session's cwd fall inside the configured full-context workspaces? */
export function matchesWorkspace(cwd, workspaces) {
  return workspaceRuleFor(cwd, workspaces) !== null
}

/** Does a session's cwd fall inside the configured full-context workspaces? */
export function isFullContextWorkspace(cwd, cfg) {
  return workspaceRuleFor(cwd, cfg === null || cfg === undefined ? [] : cfg.fullContextWorkspaces) !== null
}

/**
 * The recording level this session's cwd asks for, or `null` for the default profile.
 *
 * `null` is the important value: it means "not a full-context workspace", and
 * every caller must then behave exactly as the plugin did before this feature
 * existed. `'none'` is a different answer — a chat workspace that does record
 * the transcript but no tool traffic at all.
 */
export function workspaceLevelFor(cwd, cfg) {
  const rule = workspaceRuleFor(cwd, cfg === null || cfg === undefined ? [] : cfg.fullContextWorkspaces)
  return rule === null ? null : rule.level
}

/**
 * Pull the text out of one `user/message` event, or `''` when it carries none.
 *
 * Two shape facts drive this, both taken from dsh's session types:
 *
 * 1. A `user/message` event's `data` **is** the message; every other
 *    message-producing event nests it under `data.message`
 *    (`const message = type === 'user/message' ? record : record?.['message']`).
 * 2. Not every `user/message` is something a human typed. In one measured
 *    session 62 of 118 were real, and the 56 injected ones (runtime context,
 *    skill catalog, time context, tool-job notices, model selection) were 17×
 *    larger than the human text. Recording them would bury the conversation
 *    under material the reader never wrote — so only `source.kind === 'user'`
 *    counts.
 *
 * A replacement copy is refused too: compaction re-adds a `user/message` with
 * `surfaceOp: {op:'replace', ...}` to shadow the range it summarised, and that
 * checkpoint is not a new thing anyone said.
 *
 * @param {unknown} data the event's `data`.
 * @param {unknown} surfaceOp the event's `surfaceOp` marker.
 * @returns {string} the human-authored text, `''` when this event is not one.
 */
export function userTextOf(data, surfaceOp) {
  if (surfaceOp !== 'append') return ''
  if (data === null || typeof data !== 'object') return ''
  const source = data.source
  const kind = source !== null && typeof source === 'object' ? source.kind : undefined
  if (kind !== 'user') return ''
  return textOfBlocks(data.content)
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

/**
 * `kind=user` — something the human typed.
 *
 * Only reachable in a full-context workspace: the default profile records the
 * assistant's own final replies, which already restate what was asked. A chat
 * transcript is incomplete without the questions, so these entries exist.
 */
export function userEntry(subject, { turn, text, noteMax }) {
  return {
    payload: {
      title: firstLine(text, 120),
      note: clipText(text, noteMax),
    },
    tags: compactTags(Object.assign(baseTags(KIND.user, subject), { turn: turn })),
  }
}

/**
 * `kind=say` — one assistant message, in a full-context workspace.
 *
 * The default profile keeps only the last text-bearing assistant message of a
 * turn (the final answer). A transcript needs the whole exchange, including the
 * short narrations between tool calls, so every text-bearing message lands as
 * its own entry and `step` keeps the order visible.
 */
export function sayEntry(subject, { turn, step, text, noteMax }) {
  return {
    payload: {
      title: firstLine(text, 120),
      note: clipText(text, noteMax),
    },
    tags: compactTags(Object.assign(baseTags(KIND.say, subject), { turn: turn, step: step })),
  }
}

/**
 * `kind=tool` — one tool call, in a full-context workspace.
 *
 * `mode` decides how much survives:
 * - `none` — the caller must not call this at all;
 * - `names` — the name and error flag only (arguments and output dropped);
 * - `full` — the clipped arguments and result text too.
 *
 * Arguments arrive as a JSON-shaped value rather than a string, so they are
 * rendered with `JSON.stringify` before clipping. The result text is the
 * `tool/result` message when it has arrived; a call whose result never comes
 * records what is known and nothing more.
 *
 * @param {object} subject entry subject.
 * @param {object} input call facts plus `mode`.
 * @returns {{payload: object, tags: object} | null} the entry, or `null` when
 *   the mode records no calls.
 */
export function toolEntry(subject, { turn, step, callId, name, args, result, isError, mode, noteMax }) {
  if (mode === 'none') return null
  const toolName = typeof name === 'string' && name !== '' ? name : 'unknown'
  const summary = toolSummaryOf(args, toolName)
  const facts = []
  if (mode === 'full') {
    // `full` keeps the whole call, so the summary would only repeat it.
    const renderedArgs = renderJson(args)
    if (renderedArgs !== '') facts.push(`arguments: ${clipText(renderedArgs, Math.max(1, Math.trunc(noteMax / 2)))}`)
    if (typeof result === 'string' && result !== '') facts.push(`result: ${clipText(result, noteMax)}`)
  } else if (summary !== '') {
    // `names` stores no arguments, but it does keep the one line that says what
    // the call was for — otherwise every entry in a turn reads "工具 bash".
    facts.push(summary)
  }
  return {
    payload: {
      title: `工具 ${toolName}${isError === true ? '（出错）' : ''}`,
      note: clipText(facts.join('\n'), noteMax),
      outcome: toolName,
    },
    tags: compactTags(Object.assign(baseTags(KIND.tool, subject), {
      turn: turn,
      step: step,
      call: callId,
      tool: toolName,
      ...(isError === true ? { error: 'true' } : {}),
    })),
  }
}

/**
 * Which argument field names a summary may quote, in preference order.
 *
 * `description` first: dsh asks every `bash` call for one and the UI renders it
 * beside the command, so it is the tool author's own one-line answer to "what is
 * this step for". On a measured session all 399 `bash` calls carried one.
 *
 * The rest identify *what was touched* rather than what was passed — a path, a
 * title, a memory type. Deliberately absent: `command`, `old_string`,
 * `new_string`, `content`, `questions`. Those are the bulky bodies `full` mode
 * exists for; pulling them into a summary would make `names` as heavy as `full`
 * while still being unreadable.
 */
const SUMMARY_ARG_KEYS = ['description', 'label', 'summary', 'title', 'file_path', 'path', 'name', 'pattern', 'query', 'id']

/** Scalar argument keys rendered as `key=value` when no descriptive field exists. */
const SCALAR_ARG_KEYS = ['type', 'status', 'action', 'mode', 'level', 'op', 'operation']

/** Cap on a rendered summary, in characters. A summary that needs more is not one. */
const SUMMARY_MAX = 160

/**
 * One human-readable line describing a tool call.
 *
 * Best-effort and total: it never throws and never returns a body. When the
 * arguments offer nothing descriptive, `''` is returned and the entry keeps only
 * the tool name — the same thing `names` mode did before summaries existed.
 *
 * @param {unknown} args the call's `arguments`; dsh delivers a JSON string here
 *   in its own session log, and an already-parsed object in the live event, so
 *   both are accepted.
 * @param {unknown} name the tool name (accepted for symmetry with the entry
 *   builder; no per-tool rules are needed yet).
 * @returns {string} the summary, or `''`.
 */
export function toolSummaryOf(args, name) {
  const parsed = parseArgs(args)
  if (parsed === null) return ''
  for (const key of SUMMARY_ARG_KEYS) {
    const value = parsed[key]
    if (typeof value !== 'string') continue
    const trimmed = value.trim()
    if (trimmed === '') continue
    return trimmed.length <= SUMMARY_MAX ? trimmed : trimmed.slice(0, SUMMARY_MAX - 1) + '…'
  }
  // No descriptive field: a short scalar still says what kind of operation it was.
  const scalars = []
  for (const key of SCALAR_ARG_KEYS) {
    const value = parsed[key]
    if (typeof value !== 'string' || value.trim() === '') continue
    scalars.push(`${key}=${value.trim()}`)
  }
  return scalars.join(' ').slice(0, SUMMARY_MAX)
}

/** Parse `arguments` into a plain object, or `null` when it is not one. */
function parseArgs(args) {
  if (typeof args === 'string') {
    const trimmed = args.trim()
    if (trimmed === '' || trimmed[0] !== '{') return null
    try {
      const parsed = JSON.parse(trimmed)
      return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null
    } catch (_) {
      return null
    }
  }
  if (args === null || args === undefined || typeof args !== 'object' || Array.isArray(args)) return null
  return args
}

/** Render a JSON-shaped value for an entry body, tolerating a circular or absent one. */
function renderJson(value) {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value)
  } catch (_) {
    return ''
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

/**
 * `kind=close` — the L2b aggregate account for one goal completing.
 *
 * `objective` becomes the title (a close entry is about one goal); `distilled`
 * distinguishes an LLM aggregate from the documented skeleton degradation.
 */
export function closeEntry(subject, { goalId, objective, outcome, next, note, distilled }) {
  return {
    payload: {
      title: typeof objective === 'string' && objective !== '' ? clipText(objective, 120) : '目标收口',
      note: clipText(note, 4000),
      outcome: clipText(outcome, 2000),
      next: clipText(next, 1000),
    },
    tags: compactTags(Object.assign(baseTags(KIND.close, subject), {
      goal: goalId,
      distilled: distilled === true ? 'true' : 'false',
    })),
  }
}

/**
 * `kind=milestone` for a whole workflow run.
 *
 * `workflow/end` carries only facts (run identity, stop reason, agent count) —
 * deliberately without the result value — so this is a fact entry; the substance
 * lives in the per-subagent milestone entries.
 */
export function workflowEntry(subject, { runId, name, description, stopReason, agentsStarted, error }) {
  const facts = [`stopReason=${stopReason === undefined || stopReason === null ? 'unknown' : String(stopReason)}`]
  facts.push(`agentsStarted=${count(agentsStarted)}`)
  if (typeof error === 'string' && error !== '') facts.push(`error=${Clip(error, 200)}`)
  return {
    payload: {
      title: `工作流结束（${typeof name === 'string' && name !== '' ? name : 'unnamed'}）`,
      note: facts.join('\n') + (typeof description === 'string' && description !== '' ? `\n${description}` : ''),
      outcome: stopReason === undefined || stopReason === null ? '' : String(stopReason),
    },
    tags: compactTags(Object.assign(baseTags(KIND.milestone, subject), {
      run: runId,
      role: 'workflow',
    })),
  }
}

function Clip(value, max) {
  return typeof value === 'string' ? clipText(value, max) : ''
}

/** System instruction for the L2b close distillation. */
export const DISTILL_SYSTEM = [
  '你是 dsh 会话的收口蒸馏器。输入是一个会话在忆时塔里的活动时间线（每行一条：时间戳 + JSON 条目 + 标签）。',
  '请把它提炼成一次收口的聚合账，只依据给定材料，不要臆造。',
  '严格输出一个 JSON 对象，不要任何额外文字或代码块：',
  '{"outcome":"产出物与结果（提交/文件/数字等可核对的结论）","next":"下一步或续接抓手；没有就空串","note":"3~6 句收口叙述：做了什么、关键决策、结果"}',
].join('\n')

/**
 * Build the one-shot distillation prompt from the tower's own entries.
 *
 * Per D11 the material is the tower timeline only — the plugin never re-reads
 * the session's raw conversation.
 */
export function buildDistillPrompt({ goalId, objective, timeline }) {
  const head = [
    '【目标】',
    `goalId: ${typeof goalId === 'string' && goalId !== '' ? goalId : '(未知)'}`,
    `objective: ${typeof objective === 'string' && objective !== '' ? objective : '(未记录)'}`,
    '',
    '【本会话在忆时塔中的活动时间线（最新在前）】',
  ].join('\n')
  const body = typeof timeline === 'string' && timeline.trim() !== '' ? timeline.trim() : '(无条目)'
  return `${head}\n${body}\n\n【输出】只输出约定的 JSON 对象。`
}

/**
 * Parse the distillation reply tolerantly.
 *
 * A small local model will sometimes wrap the JSON in prose or a code fence, so
 * the first `{`…last `}` span wins; anything unparseable degrades to "the whole
 * reply is the note" rather than throwing away the paid-for output.
 */
export function parseDistillReply(text) {
  if (typeof text !== 'string') return { outcome: '', next: '', note: '' }
  const trimmed = text.trim()
  if (trimmed === '') return { outcome: '', next: '', note: '' }
  const start = trimmed.indexOf('{')
  const end = trimmed.lastIndexOf('}')
  if (start >= 0 && end > start) {
    try {
      const parsed = JSON.parse(trimmed.slice(start, end + 1))
      if (parsed !== null && typeof parsed === 'object') {
        const outcome = typeof parsed.outcome === 'string' ? parsed.outcome.trim() : ''
        const next = typeof parsed.next === 'string' ? parsed.next.trim() : ''
        const note = typeof parsed.note === 'string' ? parsed.note.trim() : ''
        if (outcome !== '' || next !== '' || note !== '') return { outcome, next, note }
      }
    } catch (_) {
      // fall through to the plain-text degradation
    }
  }
  return { outcome: '', next: '', note: trimmed }
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
 * Effective workspace rows from either a text-area string or a structured array.
 *
 * Tolerant on purpose: the row config may have been written by hand (a string,
 * the text-area form) or by the settings page (an array). A malformed level
 * defaults rather than deleting the workspace, because dropping it would turn
 * recording off for a session the user meant to record.
 */
function pickWorkspaces(value) {
  return parseWorkspaceList(value)
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
    chatType: pick(c.chatType, e.DSH_MEM_BRIDGE_CHAT_TYPE, TYPE_CHAT),
    queueMax: pickNumber(c.queueMax ?? e.DSH_MEM_BRIDGE_QUEUE_MAX, 500),
    retryMax: pickNumber(c.retryMax ?? e.DSH_MEM_BRIDGE_RETRY_MAX, 5),
    retryBackoffMs: pickNumber(c.retryBackoffMs ?? e.DSH_MEM_BRIDGE_RETRY_BACKOFF_MS, 250),
    turnNoteMax: pickNumber(c.turnNoteMax ?? e.DSH_MEM_BRIDGE_TURN_NOTE_MAX, 6000),
    compactNoteMax: pickNumber(c.compactNoteMax ?? e.DSH_MEM_BRIDGE_COMPACT_NOTE_MAX, 16000),
    milestoneNoteMax: pickNumber(c.milestoneNoteMax ?? e.DSH_MEM_BRIDGE_MILESTONE_NOTE_MAX, 2000),
    goalNoteMax: pickNumber(c.goalNoteMax ?? e.DSH_MEM_BRIDGE_GOAL_NOTE_MAX, 2000),
    turnMinTools: pickNumber(c.turnMinTools ?? e.DSH_MEM_BRIDGE_TURN_MIN_TOOLS, 1),
    turnMinLen: pickNumber(c.turnMinLen ?? e.DSH_MEM_BRIDGE_TURN_MIN_LEN, 120),
    // L2b 聚合蒸馏（M3）：总开关 / 模型覆盖 / 取塔内尾部条目数 / 每日 LLM 上限
    distill: pickBool(c.distill ?? e.DSH_MEM_BRIDGE_DISTILL, true),
    distillProvider: pick(c.distillProvider, e.DSH_MEM_BRIDGE_PROVIDER, ''),
    distillModel: pick(c.distillModel, e.DSH_MEM_BRIDGE_MODEL, ''),
    tailN: pickNumber(c.tailN ?? e.DSH_MEM_BRIDGE_TAIL_N, 20),
    maxDaily: pickNumber(c.maxDaily ?? e.DSH_MEM_BRIDGE_MAX_DAILY, 20),
    projMap,
    // 全上下文工作区：每个工作区自带录入级别；空列表 = 该功能完全不生效（默认），
    // 故默认装载与旧版逐字节一致。
    fullContextWorkspaces: pickWorkspaces(c.fullContextWorkspaces ?? e.DSH_MEM_BRIDGE_FULL_CONTEXT),
    sayNoteMax: pickNumber(c.sayNoteMax ?? e.DSH_MEM_BRIDGE_SAY_NOTE_MAX, 20000),
    toolNoteMax: pickNumber(c.toolNoteMax ?? e.DSH_MEM_BRIDGE_TOOL_NOTE_MAX, 2000),
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

/**
 * The `mem/type_create` arguments for one {@link typeSpecs} entry.
 *
 * `mem/type_create` is **not** idempotent (an existing type throws), which is
 * why the caller pairs this with {@link typeReviveArgs} on the "already exists"
 * error rather than probing first: a probe costs a round trip on every boot,
 * while the error path only runs once.
 */
export function typeCreateArgs(spec) {
  return {
    name: spec.name,
    description: spec.description,
    levels: spec.levels,
    auto_summarize: spec.autoSummarize,
    summary_group_by: spec.summaryGroupBy,
  }
}

/**
 * The `mem/type_update` arguments that make an existing type match `spec`.
 *
 * `type_update` is not an upsert either — it refuses an unknown type — so this
 * is only ever attempted after `type_create` reports "already exists". `levels`
 * is deliberately absent: 忆时塔 forbids changing it (the materialised bucket
 * chain is irreversible), and passing the same value back is merely accepted as
 * a no-op. Leaving it out also means a type this bridge did not create is never
 * silently re-leveled by a save.
 */
export function typeReviveArgs(spec) {
  return {
    name: spec.name,
    description: spec.description,
    auto_summarize: spec.autoSummarize,
    summary_group_by: spec.summaryGroupBy,
  }
}

/**
 * Does a `mem/type_create` failure mean "the type is already there"?
 *
 * Matched on the tower's own wording (`类型已存在`) because the MCP layer
 * reports it as a tool error string rather than a structured code. A false
 * negative only costs an extra revive attempt; a false positive would skip
 * creation of a genuinely missing type, so the phrasing is kept narrow.
 */
export function isTypeExistsFailure(message) {
  if (typeof message !== 'string') return false
  return message.includes('类型已存在') || /type .*already exists/i.test(message)
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

/**
 * May a failed write be attempted again?
 *
 * Only when we are certain the request was never delivered. 忆时塔 was measured
 * (2026-09-12) to leave roughly one request in eight hanging forever: the tower
 * applies the append and then never answers, so a retry writes the entry a
 * SECOND time. That is precisely how duplicate entries appeared in production.
 *
 * A timeout or a mid-flight connection reset is therefore terminal here: the
 * outcome is unknown, and an occasional missing entry is far cheaper than a
 * duplicated one (duplicates inflate every summary that reads the window).
 * Connect failures — refused, unreachable, unknown host — provably never
 * reached the server, so those stay retryable.
 *
 * @param {unknown} error the rejection from one write attempt.
 * @returns {boolean} whether another attempt is safe.
 */
export function isRetryableWriteFailure(error) {
  if (error === null || error === undefined || typeof error !== 'object') return false
  const name = typeof error.name === 'string' ? error.name : ''
  const message = typeof error.message === 'string' ? error.message : ''
  if (name === 'AbortError' || name === 'TimeoutError') return false
  const detail = message + ' ' + (typeof error.cause === 'object' && error.cause !== null && typeof error.cause.code === 'string' ? error.cause.code : '')
  return /ECONNREFUSED|EHOSTUNREACH|ENETUNREACH|ENOTFOUND|EAI_AGAIN/i.test(detail)
}
