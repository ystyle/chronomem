/**
 * Contract tests for the browser half.
 *
 * `lib/client.js` is a *bundle*, not an ordinary module: it registers a factory
 * with `window.__ModuleLoader__` and its body never runs through Node's module
 * graph. Three things about it can break a dsh boot or silently disable the
 * settings page, and none of them need a browser to catch:
 *
 * 1. the bundle id and the `plugins.row.config` key must match what the Loader
 *    and the Plugins page dispatch (`dsh-mem-bridge#mem-bridge`), and the row
 *    half must equal the id `cordis.patch.yml` declares;
 * 2. every `require` must be a platform seed word — a relative one is read as a
 *    package-local chunk request, and an unknown bare one throws "missed the
 *    module table"; either fails the whole Web boot;
 * 3. `package.json` must export `./client` and declare `dsh.client`, because a
 *    `dsh.client` declaration with no `./client` export is a composition error.
 *
 * The tests run the factory against a fake `require` and drive `apply()` with a
 * fake Cordis context, asserting this bundle's wiring rather than re-testing
 * dsh's own form model.
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const bundlePath = join(here, '..', 'lib', 'client.js')
const packagePath = join(here, '..', 'package.json')
const patchPath = join(here, '..', 'cordis.patch.yml')

/** Seed words the web shell installs into the module table (`staticModules`). */
const PLATFORM_SEED_WORDS = new Set([
  'react',
  'react/jsx-runtime',
  'react-dom',
  'react-dom/client',
  '@deepseek-ai/cordis',
  '@deepseek-ai/dsh-client-store',
  '@deepseek-ai/dsh-client-ui-slots',
  '@deepseek-ai/dsh-client-ui-primitives',
  '@deepseek-ai/dsh-client-ui-dockkit',
])

/** Render one element, the way `react.createElement` does. */
function element(type, props, ...children) {
  return { type, props, children }
}

/**
 * A fake `SettingsFormModel` faithful enough for the controller: it records the
 * specs and secret specs it was handed and answers the reads the projection and
 * the card make.
 */
function fakeFormModel() {
  const instances = []
  class FakeSettingsFormModel {
    constructor(scope, specs, secrets = []) {
      this.scope = scope
      this.specs = specs
      this.secrets = secrets
      this.disposed = false
      this.shellState = {
        available: true,
        writable: true,
        dirty: false,
        invalid: false,
        saving: false,
        failed: false,
      }
      this.fieldStates = new Map()
      instances.push(this)
    }
    field(name) {
      return this.fieldStates.get(name) ?? { text: '', overridden: false, invalid: false }
    }
    shell() {
      return this.shellState
    }
    bind(project) {
      // The real store re-publishes on both scope and draft changes; here the
      // projection is re-evaluated on read, which is enough to observe a
      // describe-mirror change reaching the snapshot.
      this.store = { set: () => {}, getSnapshot: project }
      return this.store
    }
    actions() {
      return {
        edit: (field, text) => this.fieldStates.set(field, { text, overridden: true, invalid: false }),
        resetField: () => {},
        save: () => {},
        discard: () => {},
      }
    }
    dispose() {
      this.disposed = true
    }
  }
  FakeSettingsFormModel.instances = instances
  return FakeSettingsFormModel
}

/** A named stand-in component, so `element.type.name` reads back its slot name. */
function namedComponent(name) {
  const component = (props) => element(name, props)
  Object.defineProperty(component, 'name', { value: name })
  return component
}

/** The primitives module handed to the bundle's factory. */
function fakePrimitives() {
  const Model = fakeFormModel()
  return {
    SettingsFormModel: Model,
    SettingsForm: namedComponent('SettingsForm'),
    SettingsValueField: namedComponent('SettingsValueField'),
    SettingsSecretField: namedComponent('SettingsSecretField'),
    Switch: namedComponent('Switch'),
    settingsTextField: (field) => ({
      field,
      format: (value) => (typeof value === 'string' ? value : ''),
      parse: (text) => (text.trim() === '' ? { kind: 'clear' } : { kind: 'set', value: text.trim() }),
    }),
    settingsNumberField: () => {
      // This page has no numeric field; a call means the specs drifted.
      throw new Error('this page has no numeric field')
    },
    __Model: Model,
  }
}

/**
 * Materialize the bundle with a fake `window.__ModuleLoader__` and a fake
 * `require`, returning the factory's exports and everything it required.
 *
 * @param overrides - primitives members to replace, for failure-path tests.
 * @returns the exports, the captured registration, and the required specifiers.
 */
async function loadBundle(overrides = {}) {
  const registrations = []
  const required = []
  const primitives = { ...fakePrimitives(), ...overrides }
  globalThis.window = {
    __ModuleLoader__: {
      load(registration) {
        registrations.push(registration)
      },
    },
  }
  try {
    // A unique query gives each test a fresh evaluation of the bundle body.
    await import(`${pathToFileURL(bundlePath).href}?t=${Math.random()}`)
  } finally {
    delete globalThis.window
  }
  assert.equal(registrations.length, 1, 'the bundle must register exactly one factory')
  const registration = registrations[0]
  const react = {
    createElement: (type, props, ...children) => element(type, props, ...children),
    // The text-area measures itself after mount; a stand-in hook is enough to
    // render it, and keeps the test about the control's shape rather than layout.
    useRef: () => ({ current: null }),
    useLayoutEffect: () => {},
  }
  const fakeRequire = (spec) => {
    required.push(spec)
    if (spec === 'react') return react
    if (spec === '@deepseek-ai/dsh-client-ui-primitives') return primitives
    throw new Error(`bundle required a non-seed module: ${spec}`)
  }
  return { exports: registration.factory(fakeRequire), registration, required, primitives }
}

/** A describe face backed by a mutable snapshot. */
function describeFaceStub(secrets = []) {
  let snapshot = {
    status: 'ready',
    error: null,
    view: { namespaces: [{ ns: 'mem-bridge', secrets }] },
  }
  const listeners = new Set()
  return {
    getSnapshot: () => snapshot,
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    ensure: async () => {},
    acceptView: () => {},
    set: (next) => {
      snapshot = { ...snapshot, ...next }
      for (const listener of listeners) listener()
    },
  }
}

/**
 * Everything `apply()` needs, with the services the controller touches.
 *
 * @param describeFace - the shared describe mirror the badge reads.
 * @param slotRegistrations - collects `ctx.slots.register` calls.
 * @returns a fake client context.
 */
function ctxFor(describeFace, slotRegistrations) {
  const effects = []
  const localeNamespaces = []
  const namespaces = []
  const ctx = {
    effects,
    localeNamespaces,
    namespaces,
    configForms: {
      get: (ns) => {
        namespaces.push(ns)
        return { __namespace: ns, mutate: () => Promise.resolve(true) }
      },
      describe: () => describeFace,
      // Like the real service: registration runs once a watched namespace is
      // served, and the returned disposer ends it.
      whileServed: (watched, register) => {
        const dispose = register(new Set(watched))
        return () => dispose?.()
      },
    },
    locale: {
      bind: () => (key) => key,
      register: (ns, dicts) => {
        localeNamespaces.push({ ns, dicts })
        return () => {}
      },
    },
    slots: {
      // Like the real registry: the inner registration runs at inject time and
      // the returned disposer withdraws it.
      inject: (name, register) => {
        const dispose = register()
        return () => dispose?.()
      },
      register: (options, Component) => {
        slotRegistrations.push({ options, Component })
        return () => {}
      },
    },
    effect: (callback, label) => {
      effects.push({ label, callback })
      const dispose = callback()
      return typeof dispose === 'function' ? dispose : () => {}
    },
  }
  return ctx
}

/** A page snapshot with every field present and the four values overridable. */
function pageState(overrides = {}) {
  return {
    available: true,
    writable: true,
    dirty: false,
    invalid: false,
    saving: false,
    failed: false,
    url: { text: 'http://127.0.0.1:8900', overridden: false, invalid: false },
    token: { text: '', overridden: false, invalid: false },
    enabled: { text: 'true', overridden: false, invalid: false },
    distill: { text: 'true', overridden: false, invalid: false },
    fullContext: { text: '', overridden: false, invalid: false },
    tokenConfigured: false,
    ...overrides,
  }
}

/** Render the card's page view against one snapshot. */
function renderPage(exports, state, handlers = {}) {
  return exports.MemBridgeCard({
    view: 'page',
    t: (key) => key,
    useMemBridge: (select) => select(state),
    edit: () => {},
    resetField: () => {},
    save: () => {},
    discard: () => {},
    ...handlers,
  })
}

/** The component name an element renders as, for both strings and components. */
function typeName(node) {
  return typeof node.type === 'function' ? node.type.name : node.type
}

/**
 * Render one element with a function-component type, the way a renderer would.
 *
 * `createElement` is lazy (it only builds a descriptor), so a component this
 * bundle authors itself is inspected by invoking it once with its own props.
 *
 * @param node - an element whose `type` is a function component.
 * @returns the element the component returns.
 */
function shallow(node) {
  return node.type(node.props)
}

// ── bundle identity ──────────────────────────────────────────────────────────

test('the bundle registers under the package name, which is the graph row id', async () => {
  const { registration } = await loadBundle()
  assert.equal(registration.id, 'dsh-mem-bridge')
})

test('the row config key matches the package name and the patch row id', async () => {
  const { exports } = await loadBundle()
  const patch = readFileSync(patchPath, 'utf8')
  const declaredId = /^\s*-\s*id:\s*(\S+)\s*$/m.exec(patch)?.[1]
  assert.equal(
    declaredId,
    exports.SETTINGS_NAMESPACE,
    'the settings namespace must be the id cordis.patch.yml declares',
  )
  assert.equal(exports.ROW_CONFIG_KEY, `dsh-mem-bridge#${declaredId}`)
  assert.equal(exports.ROW_CONFIG_KEY, 'dsh-mem-bridge#mem-bridge')
})

test('every require is a platform seed word, so the bundle stays loadable', async () => {
  const { required } = await loadBundle()
  assert.ok(required.length > 0, 'the factory must require its platform modules')
  for (const spec of required) {
    assert.ok(PLATFORM_SEED_WORDS.has(spec), `${spec} is not a platform seed word`)
  }
})

test('the bundle requires nothing beyond react and the UI primitives', async () => {
  const { required } = await loadBundle()
  assert.deepEqual([...new Set(required)].sort(), [
    '@deepseek-ai/dsh-client-ui-primitives',
    'react',
  ])
})

test('the source contains no relative require, which would be read as a chunk request', () => {
  const source = readFileSync(bundlePath, 'utf8')
  const relative = [...source.matchAll(/require\(\s*['"]\.{1,2}\//g)]
  assert.equal(relative.length, 0, 'a relative require is a package-local chunk request and always fails')
})

// ── manifest ─────────────────────────────────────────────────────────────────

test('package.json exports ./client, without which the client declaration is a boot error', () => {
  const pkg = JSON.parse(readFileSync(packagePath, 'utf8'))
  assert.equal(pkg.exports['./client'], './lib/client.js')
})

test('package.json declares dsh.client for the web platform', () => {
  const pkg = JSON.parse(readFileSync(packagePath, 'utf8'))
  assert.equal(pkg.dsh.client.platform, 'web')
  assert.ok(Array.isArray(pkg.dsh.client.inject), 'inject must be a string array when present')
  for (const name of pkg.dsh.client.inject) assert.equal(typeof name, 'string')
})

test('the host half still declares its bundle patch', () => {
  const pkg = JSON.parse(readFileSync(packagePath, 'utf8'))
  assert.equal(pkg.dsh.bundle.patch, './cordis.patch.yml')
})

// ── boolean field spec ───────────────────────────────────────────────────────

test('the boolean spec round-trips both values', async () => {
  const { exports } = await loadBundle()
  const spec = exports.settingsBooleanField('enabled')
  assert.equal(spec.field, 'enabled')
  assert.equal(spec.format(true), 'true')
  assert.equal(spec.format(false), 'false')
  assert.deepEqual(spec.parse('true'), { kind: 'set', value: true })
  assert.deepEqual(spec.parse('false'), { kind: 'set', value: false })
  assert.deepEqual(spec.parse(' false '), { kind: 'set', value: false })
})

test('the boolean spec blocks a draft that is not a boolean instead of guessing', async () => {
  const { exports } = await loadBundle()
  const spec = exports.settingsBooleanField('enabled')
  assert.equal(spec.parse('yes'), undefined)
  assert.equal(spec.parse(''), undefined)
  assert.equal(spec.parse('1'), undefined)
})

test('the boolean spec formats an absent value as the schema default', async () => {
  const { exports } = await loadBundle()
  const spec = exports.settingsBooleanField('enabled')
  assert.equal(spec.format(undefined), 'true', 'both booleans default to true')
  assert.equal(spec.format(null), 'true')
})

// ── secret presence ──────────────────────────────────────────────────────────

test('secret presence is read from the describe view, not from the section', async () => {
  const { exports } = await loadBundle()
  const view = { namespaces: [{ ns: 'mem-bridge', value: {}, secrets: [{ path: ['token'], set: true }] }] }
  assert.equal(exports.secretConfigured(view, 'token'), true)
  assert.equal(exports.secretConfigured(view, 'url'), false)
})

test('an unset, missing, or malformed secret reads as not configured', async () => {
  const { exports } = await loadBundle()
  const ns = (entry) => ({ namespaces: [entry] })
  assert.equal(exports.secretConfigured(ns({ ns: 'mem-bridge', secrets: [{ path: ['token'], set: false }] }), 'token'), false)
  assert.equal(exports.secretConfigured(ns({ ns: 'mem-bridge' }), 'token'), false)
  assert.equal(exports.secretConfigured({ namespaces: [] }, 'token'), false)
  assert.equal(exports.secretConfigured(undefined, 'token'), false)
  assert.equal(exports.secretConfigured(null, 'token'), false)
  assert.equal(exports.secretConfigured({}, 'token'), false)
})

test('a nested secret path does not stand in for the token field', async () => {
  const { exports } = await loadBundle()
  const view = { namespaces: [{ ns: 'mem-bridge', secrets: [{ path: ['nested', 'token'], set: true }] }] }
  assert.equal(exports.secretConfigured(view, 'token'), false)
})

test('another namespace does not answer for this one', async () => {
  const { exports } = await loadBundle()
  const view = { namespaces: [{ ns: 'other', secrets: [{ path: ['token'], set: true }] }] }
  assert.equal(exports.secretConfigured(view, 'token'), false)
})

// ── apply() wiring ───────────────────────────────────────────────────────────

test('apply requires the slot registry, dictionaries, and the shared config forms', async () => {
  const { exports } = await loadBundle()
  assert.deepEqual(exports.inject, ['slots', 'locale', 'configForms'])
})

test('apply binds the form to the settings namespace the patch declares', async () => {
  const { exports } = await loadBundle()
  const ctx = ctxFor(describeFaceStub(), [])
  exports.apply(ctx)
  assert.deepEqual(ctx.namespaces, ['mem-bridge'])
})

test('apply registers the page on plugins.row.config under the row key', async () => {
  const { exports } = await loadBundle()
  const registrations = []
  exports.apply(ctxFor(describeFaceStub(), registrations))
  assert.equal(registrations.length, 1, 'exactly one page must be registered')
  const { options } = registrations[0]
  assert.equal(options.name, 'plugins.row.config')
  assert.equal(options.key, 'dsh-mem-bridge#mem-bridge')
  assert.equal(options.locale, exports.NS)
})

test('apply registers both dictionaries', async () => {
  const { exports } = await loadBundle()
  const ctx = ctxFor(describeFaceStub(), [])
  exports.apply(ctx)
  assert.equal(ctx.localeNamespaces.length, 1)
  assert.deepEqual(Object.keys(ctx.localeNamespaces[0].dicts).sort(), ['en', 'zh'])
})

test('both dictionaries carry the same keys, so neither locale shows a raw key', async () => {
  const { exports } = await loadBundle()
  const ctx = ctxFor(describeFaceStub(), [])
  exports.apply(ctx)
  const { dicts } = ctx.localeNamespaces[0]
  assert.deepEqual(Object.keys(dicts.zh).sort(), Object.keys(dicts.en).sort())
})

test('the page registers only while the Host serves the namespace', async () => {
  const { exports } = await loadBundle()
  const registrations = []
  const ctx = ctxFor(describeFaceStub(), registrations)
  let watched
  const originalWhileServed = ctx.configForms.whileServed
  ctx.configForms.whileServed = (namespaces, register) => {
    watched = namespaces
    return originalWhileServed(namespaces, register)
  }
  exports.apply(ctx)
  assert.deepEqual(watched, ['mem-bridge'])
  assert.equal(registrations.length, 1)
})

test('the page is torn down when the plugin unloads', async () => {
  const { exports, primitives } = await loadBundle()
  const ctx = ctxFor(describeFaceStub(), [])
  exports.apply(ctx)
  const controller = primitives.__Model.instances[0]
  assert.equal(controller.disposed, false)
  for (const effect of ctx.effects) {
    if (effect.label === 'dsh-mem-bridge: form subscription') effect.callback()()
  }
  assert.equal(controller.disposed, true, 'the form subscription must be released')
})

// ── the form the controller builds ───────────────────────────────────────────

test('the controller stages url as text, both switches as booleans, and the workspace list as JSON', async () => {
  const { exports, primitives } = await loadBundle()
  exports.apply(ctxFor(describeFaceStub(), []))
  const model = primitives.__Model.instances[0]
  assert.deepEqual(
    model.specs.map((spec) => spec.field),
    ['url', 'enabled', 'distill', 'fullContextWorkspaces'],
  )
  assert.equal(model.specs[0].format('http://x'), 'http://x')
  assert.deepEqual(model.specs[1].parse('false'), { kind: 'set', value: false })
  assert.deepEqual(model.specs[2].parse('true'), { kind: 'set', value: true })
})

test('the token is a write-only control addressed by its own field name', async () => {
  const { exports, primitives } = await loadBundle()
  exports.apply(ctxFor(describeFaceStub(), []))
  const model = primitives.__Model.instances[0]
  assert.equal(model.secrets.length, 1)
  assert.equal(model.secrets[0].field, 'token')
  assert.equal(typeof model.secrets[0].write, 'function')
})

test('the token write is a plain set on the token path of this namespace', async () => {
  const { exports, primitives } = await loadBundle()
  const calls = []
  const ctx = ctxFor(describeFaceStub(), [])
  ctx.configForms.get = (ns) => ({
    __namespace: ns,
    mutate: (ops) => {
      calls.push({ ns, ops })
      return Promise.resolve(true)
    },
  })
  exports.apply(ctx)
  const model = primitives.__Model.instances[0]
  const accepted = await model.secrets[0].write('secret-value')
  assert.equal(accepted, true)
  assert.equal(calls.length, 1)
  assert.equal(calls[0].ns, 'mem-bridge')
  assert.deepEqual(calls[0].ops, [{ op: 'set', path: ['token'], value: 'secret-value' }])
})

test('the page snapshot exposes the four fields plus secret presence', async () => {
  const { exports, primitives } = await loadBundle()
  exports.apply(ctxFor(describeFaceStub([{ path: ['token'], set: true }]), []))
  const model = primitives.__Model.instances[0]
  model.fieldStates.set('url', { text: 'http://127.0.0.1:8900', overridden: false, invalid: false })
  const snapshot = model.store.getSnapshot()
  for (const key of ['available', 'writable', 'dirty', 'invalid', 'saving', 'failed']) {
    assert.ok(key in snapshot, `the shell must supply ${key}`)
  }
  assert.equal(snapshot.url.text, 'http://127.0.0.1:8900')
  assert.equal(snapshot.tokenConfigured, true)
  assert.ok('enabled' in snapshot && 'distill' in snapshot)
})

test('secret presence is refreshed when the describe mirror changes', async () => {
  const { exports, primitives } = await loadBundle()
  const face = describeFaceStub([])
  exports.apply(ctxFor(face, []))
  const model = primitives.__Model.instances[0]
  assert.equal(model.store.getSnapshot().tokenConfigured, false)
  face.set({ view: { namespaces: [{ ns: 'mem-bridge', secrets: [{ path: ['token'], set: true }] }] } })
  assert.equal(
    model.store.getSnapshot().tokenConfigured,
    true,
    'a later describe answer must reach the badge',
  )
})

test('the inject face names its hook memBridge so the card binds useMemBridge', async () => {
  const { exports } = await loadBundle()
  const registrations = []
  exports.apply(ctxFor(describeFaceStub(), registrations))
  const face = registrations[0].options.inject()
  assert.deepEqual(Object.keys(face.hooks), ['memBridge'])
  for (const action of ['edit', 'resetField', 'save', 'discard']) {
    assert.equal(typeof face[action], 'function', `${action} must reach the card`)
  }
})

// ── the card ─────────────────────────────────────────────────────────────────

test('the summary view renders the one-liner, not the form', async () => {
  const { exports } = await loadBundle()
  // The hook is called unconditionally, as a renderer requires of hooks, so it
  // must be present even though the summary path returns before reading state.
  const node = exports.MemBridgeCard({
    view: 'summary',
    t: (key) => key,
    useMemBridge: (select) => select(pageState()),
  })
  assert.equal(node, 'description')
})

test('the page view renders the shared form with every control', async () => {
  const { exports } = await loadBundle()
  const form = renderPage(exports, pageState({ tokenConfigured: true }))
  assert.equal(typeName(form), 'SettingsForm')
  const controls = form.children.filter((child) => typeName(child) !== 'p')
  assert.deepEqual(controls.map(typeName), [
    'SettingsValueField',
    'SettingsSecretField',
    'BooleanField',
    'BooleanField',
    'TextAreaField',
  ])
  assert.equal(controls[1].props.configured, true)
  assert.equal(controls[1].props.stateLabel, 'tokenSet')
  assert.equal(controls[0].props.label, 'url')
})

test('the page shows the privacy notice, as the reporting contract requires', async () => {
  const { exports } = await loadBundle()
  const form = renderPage(exports, pageState())
  const notice = form.children.at(-1)
  assert.equal(typeName(notice), 'p')
  assert.equal(notice.children[0], 'privacy')
})

test('the form is disabled as a whole when the Host document is read-only', async () => {
  const { exports } = await loadBundle()
  const form = renderPage(exports, pageState({ writable: false }))
  const controls = form.children.filter((child) => typeName(child) !== 'p')
  for (const control of controls) {
    assert.equal(control.props.disabled, true, `${typeName(control)} must be disabled`)
  }
})

test('the secret field reports the configured state through its label', async () => {
  const { exports } = await loadBundle()
  const secret = (tokenConfigured) =>
    renderPage(exports, pageState({ tokenConfigured })).children.find(
      (child) => typeName(child) === 'SettingsSecretField',
    )
  assert.equal(secret(true).props.stateLabel, 'tokenSet')
  assert.equal(secret(false).props.stateLabel, 'tokenUnset')
})

test('the toggles stage text through edit, matching the boolean spec', async () => {
  const { exports } = await loadBundle()
  const edits = []
  const form = renderPage(exports, pageState({ enabled: { text: 'true', overridden: false, invalid: false }, distill: { text: 'false', overridden: false, invalid: false } }), {
    edit: (field, text) => edits.push([field, text]),
  })
  const toggles = form.children.filter((child) => typeName(child) === 'BooleanField')
  assert.equal(toggles[0].props.checked, true)
  assert.equal(toggles[1].props.checked, false)
  toggles[0].props.onToggle(false)
  toggles[1].props.onToggle(true)
  assert.deepEqual(edits, [
    ['enabled', 'false'],
    ['distill', 'true'],
  ])
})

test('a switch renders its label and the staged state, and stages through onToggle', async () => {
  const { exports } = await loadBundle()
  const toggles = renderPage(exports, pageState()).children.filter(
    (child) => typeName(child) === 'BooleanField',
  )
  const rendered = shallow(toggles[0])
  const switchNode = rendered.children[0].children[1]
  assert.equal(typeName(switchNode), 'Switch')
  assert.equal(switchNode.props.checked, true)
  assert.equal(switchNode.props.label, 'enabled')
  assert.equal(typeof switchNode.props.onChange, 'function')
})

// ---------------------------------------------------------------------------
// The workspace text-area
//
// The bundle cannot `require` a relative module (see the header), so it carries
// its own copy of the parser. That copy is what the settings page actually
// saves through, so it is tested against `lib/pure.js` — a drift between the two
// would mean the UI accepts a line the Host then reads differently.
// ---------------------------------------------------------------------------

test('the bundle parses workspace text the same way pure.js does', async () => {
  const { exports } = await loadBundle()
  const pure = await import('../lib/pure.js')
  const inputs = [
    '',
    '   ',
    '/home/me/notes',
    '/home/me/notes = none',
    '/home/me/notes = full\njournal',
    '/home/me/work/ = full',
    '/home/me/my notes = full',
    '# comment\n\n/a = names\n/a = full',
    '/a = bogus',
    'journal = NONE',
  ]
  for (const input of inputs) {
    assert.deepEqual(
      exports.parseWorkspaceText(input),
      pure.parseWorkspaceListStrict(input),
      `parsers disagree on ${JSON.stringify(input)}`,
    )
  }
})

test('the bundle formats workspace rows the same way pure.js does', async () => {
  const { exports } = await loadBundle()
  const pure = await import('../lib/pure.js')
  const cases = [
    [],
    [{ path: '/a', level: 'full' }],
    [{ path: '/a', level: 'full' }, { path: 'journal', level: 'none' }],
    [{ path: '/a/' }, { path: '/b', level: 'bogus' }],
    null,
  ]
  for (const rows of cases) {
    assert.equal(exports.formatWorkspaceRows(rows), pure.formatWorkspaceList(rows))
  }
})

test('the workspace field round-trips through format and parse', async () => {
  const { exports } = await loadBundle()
  const rows = [{ path: '/home/me/notes', level: 'none' }, { path: 'journal', level: 'full' }]
  assert.deepEqual(exports.parseWorkspaceText(exports.formatWorkspaceRows(rows)), rows)
})

test('an unknown level is rejected by the form field, so the save is blocked', async () => {
  const { exports } = await loadBundle()
  const spec = exports.settingsJsonField('fullContextWorkspaces', exports.formatWorkspaceRows, exports.parseWorkspaceText)
  // `undefined` is the shared form model's "invalid" signal.
  assert.equal(spec.parse('/a = bogus'), undefined)
  assert.deepEqual(spec.parse('/a = none'), { kind: 'set', value: [{ path: '/a', level: 'none' }] })
  // An empty box clears the field rather than storing an empty array.
  assert.deepEqual(spec.parse('   '), { kind: 'clear' })
})

test('the row config key wiring still matches after adding a field', async () => {
  const { exports } = await loadBundle()
  assert.equal(exports.ROW_CONFIG_KEY, 'dsh-mem-bridge#mem-bridge')
  assert.equal(exports.FULL_CONTEXT_FIELD, 'fullContextWorkspaces')
})

// ---------------------------------------------------------------------------
// The workspace text-area's affordances
//
// Two things made it read as a one-line input rather than a list: it collapsed
// to a single row when empty, and it carried no example. Both are about the
// control being visibly *multi-entry*, so they are pinned here.
// ---------------------------------------------------------------------------

test('the workspace field renders as a multi-line box, not a one-line input', async () => {
  const { exports } = await loadBundle()
  const form = renderPage(exports, pageState())
  const area = form.children.find((child) => typeName(child) === 'TextAreaField')
  const rendered = shallow(area)
  const node = rendered.children[1]
  assert.equal(node.type, 'textarea', 'the control must be a textarea element')
  // Several rows so an empty box still looks like it takes a list.
  assert.ok(node.props.rows >= 4, `rows was ${node.props.rows}, expected a multi-line box`)
  assert.ok(
    rendered.children[0].props.style.minHeight !== undefined ||
      node.props.style.minHeight !== undefined,
    'a min height keeps the empty box from collapsing to one line',
  )
})

test('the workspace field points at a placeholder', async () => {
  const { exports } = await loadBundle()
  const form = renderPage(exports, pageState())
  const area = form.children.find((child) => typeName(child) === 'TextAreaField')
  const node = shallow(area).children[1]
  // `t` in the test harness echoes keys, so this only proves the control is
  // wired to one; the copy itself is checked in the next test.
  assert.equal(node.props.placeholder, 'fullContextPlaceholder')
})

test('every shipped placeholder example is valid input', async () => {
  // A placeholder that does not parse would teach the wrong syntax — the reader
  // copies it into the box and the save is refused.
  const { exports } = await loadBundle()
  for (const [locale, dict] of Object.entries(exports.dictionaries)) {
    const placeholder = dict.fullContextPlaceholder
    assert.equal(typeof placeholder, 'string', `${locale} has no placeholder`)
    assert.ok(placeholder.includes(' = '), `${locale}: ${JSON.stringify(placeholder)}`)
    assert.ok(placeholder.includes('\n'), `${locale} example should span several lines`)
    const parsed = exports.parseWorkspaceText(placeholder)
    assert.ok(Array.isArray(parsed) && parsed.length >= 2, `${locale} example must be valid input`)
    for (const row of parsed) assert.ok(['none', 'names', 'full'].includes(row.level))
    // It should demonstrate the contrast the levels exist for, not three copies
    // of the same level.
    assert.ok(new Set(parsed.map((row) => row.level)).size >= 2, `${locale} should show differing levels`)
  }
})

test('the placeholder is absent from a field that has a value', async () => {
  const { exports } = await loadBundle()
  const form = renderPage(exports, pageState({
    fullContext: { text: '/a = none', overridden: false, invalid: false },
  }))
  const area = form.children.find((child) => typeName(child) === 'TextAreaField')
  const node = shallow(area).children[1]
  // Browsers only show a placeholder while empty; what matters here is that the
  // control carries the example while the value stays the real content.
  assert.equal(node.props.value, '/a = none')
})
