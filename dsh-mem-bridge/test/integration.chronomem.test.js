/**
 * Live integration self-test against a running 忆时塔.
 *
 * It exercises the real transport (streamable-HTTP MCP over JSON-RPC), the real
 * `mem/append` argument shape and the real read-back path — the part unit tests
 * cannot reach. It works entirely inside its OWN type and removes that type
 * afterwards, so a production `dsh/activity` type is never touched.
 *
 * The test SKIPS (never fails) when 忆时塔 is not running, so `npm test` stays
 * green on a machine without the tower.
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  callRequest,
  mcpHeaders,
  mcpUrl,
  parseMcpBody,
  resolveConfig,
  resultText,
  rpcFailure,
  turnEntry,
} from '../lib/pure.js'

const cfg = resolveConfig({}, process.env)
const SELFTEST_TYPE = 'selftest/dsh-mem-bridge'
const MARKER = `mem-bridge-selftest-${Date.now()}`

let nextId = 0

async function call(tool, args) {
  nextId += 1
  const response = await fetch(mcpUrl(cfg.url), {
    method: 'POST',
    headers: mcpHeaders(cfg.token),
    body: JSON.stringify(callRequest(nextId, tool, args)),
    signal: AbortSignal.timeout(10000),
  })
  const body = parseMcpBody(await response.text())
  const failure = rpcFailure(body)
  return {
    status: response.status,
    failure,
    text: failure === null ? resultText(body.result) : '',
  }
}

async function towerReachable() {
  if (cfg.enabled !== true) return false
  try {
    const probe = await call('mem/list_types', {})
    return probe.failure === null
  } catch (_) {
    return false
  }
}

test('chronomem round-trip: create → append → query → cleanup', async (t) => {
  if (!(await towerReachable())) {
    t.skip(`忆时塔 not reachable at ${mcpUrl(cfg.url)} — skipping live integration test`)
    return
  }

  try {
    // 1. Ensure our dedicated self-test type (also exercises mem/type_update when present).
    const created = await call('mem/type_create', {
      name: SELFTEST_TYPE,
      levels: ['day', 'week'],
      description: 'dsh-mem-bridge 自测类型（可随时删除）',
      auto_summarize: false,
    })
    if (created.failure !== null) {
      const updated = await call('mem/type_update', { name: SELFTEST_TYPE, auto_summarize: false, summary_group_by: [] })
      assert.equal(updated.failure, null, `type_update failed: ${updated.failure}`)
    }

    // 1b. The type's self-heal second leg: re-applying the same config must succeed
    // (a same-value `levels` is a tolerated no-op, which is what the plugin relies on).
    const ensured = await call('mem/type_update', {
      name: SELFTEST_TYPE,
      levels: ['day', 'week'],
      auto_summarize: false,
      summary_group_by: [],
    })
    assert.equal(ensured.failure, null, `idempotent type_update failed: ${ensured.failure}`)

    // 2. Append one real entry built by the very builder the plugin uses.
    const entry = turnEntry(
      { session: 'selftest-session', agent: 'selftest-session', proj: 'selftest' },
      { turn: 1, text: MARKER, toolCalls: 1, toolErrors: 0, noteMax: 6000 },
    )
    const appended = await call('mem/append', {
      type: SELFTEST_TYPE,
      payload: entry.payload,
      tags: entry.tags,
      ts: Date.now(),
    })
    assert.equal(appended.failure, null, `append failed: ${appended.failure}`)

    // 3. Read it back — proves the entry is queryable, not merely accepted.
    const queried = await call('mem/query', { type: SELFTEST_TYPE, limit: 5 })
    assert.equal(queried.failure, null, `query failed: ${queried.failure}`)
    assert.ok(queried.text.includes(MARKER), `query result did not contain ${MARKER}`)
    assert.ok(queried.text.includes('kind=turn'), 'query result did not expose the kind tag')
  } finally {
    // 4. Always clean up: truncate (empties both series) then drop the type.
    try {
      await call('mem/truncate', { type: SELFTEST_TYPE })
      await call('mem/type_delete', { type: SELFTEST_TYPE })
    } catch (_) {
      // Cleanup is best-effort; the type is explicitly marked as disposable.
    }
  }
})
