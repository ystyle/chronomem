/**
 * dsh-mem-bridge — browser half.
 *
 * The Host half registers a `Config` schema whose `.volatile()` fields are the
 * four a user actually needs to reach (url / token / enabled / distill). This
 * half renders those four on the row's own page in the Plugins panel, so the
 * deployment needs no hand-edited YAML and no environment variables.
 *
 * Contract notes (verified against the shipped dsh 0.2.1-alpha.1):
 * - A plugin Config schema alone renders nothing: the Host publishes the form
 *   through `settings.describe`, but no shipped client builds a page from a
 *   schema automatically. A page is required, and this is it.
 * - The settings *namespace* is the Loader entry id the bundle's patch
 *   declares (`mem-bridge`), NOT the Loader path (`include:mem-bridge`) and not
 *   the package name. That id is `entry.options.id`, so it must match the
 *   `plugins.row.config` key's row half exactly (`<package>#<row id>`).
 * - Only a save writes: the shared form stages every edit and writes them in
 *   one revision-fenced mutation. Nothing here writes on change.
 * - `token` carries `role('secret')`: the Host strips its literal from every
 *   describe response and reports only whether one is set, so the control
 *   cannot display the current value — an empty draft writes nothing, which
 *   keeps the stored token rather than clearing it.
 *
 * Bundle shape: `window.__ModuleLoader__.load({ id, factory })`, where `id` is
 * the package name and the factory's `require` resolves platform seed words
 * (`react`, `@deepseek-ai/dsh-client-ui-primitives`) plus already-materialized
 * package rows. The bundle is self-contained by construction: a relative
 * `require` would be read as a package-local chunk request and fail.
 */

window.__ModuleLoader__.load({
  id: 'dsh-mem-bridge',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    const react = require('react')
    const primitives = require('@deepseek-ai/dsh-client-ui-primitives')

    //#region constants

    /** Dictionary namespace this page owns. */
    const NS = 'settings.memBridge'
    /** This bundle's package name, which is the bundle half of the row config key. */
    const PACKAGE_NAME = 'dsh-mem-bridge'
    /**
     * Settings namespace of this plugin, which is also the row half of the
     * `plugins.row.config` key (`<package name>#<row id>`). The bundle patch
     * declares `id: mem-bridge`, and the Loader turns that into the settings
     * namespace; keep the two in step when renaming the row.
     */
    const SETTINGS_NAMESPACE = 'mem-bridge'
    /** Slot key the Plugins page dispatches for this row. */
    const ROW_CONFIG_KEY = PACKAGE_NAME + '#' + SETTINGS_NAMESPACE
    /** The one field the Host redacts, and therefore the one write-only control. */
    const TOKEN_FIELD = 'token'
    /** The workspace list: stored as an object array, edited as lines of text. */
    const FULL_CONTEXT_FIELD = 'fullContextWorkspaces'
    /** Levels a workspace line may carry; kept in step with the Host schema union. */
    const WORKSPACE_LEVELS = ['none', 'names', 'full']
    /** Level a line without one takes, matching the Host-side parser's default. */
    const DEFAULT_LEVEL = 'names'

    //#endregion constants

    //#region field specs

    /**
     * A boolean field.
     *
     * The shipped helpers are `settingsTextField` and `settingsNumberField`
     * only; there is no boolean spec. Reusing the text helper would render a
     * text input the user has to type `true`/`false` into, so this spec keeps
     * the staged-form contract (format in, parse out, `clear` unsets) while the
     * control is a switch.
     *
     * An absent value formats as `true`, which is what the schema's
     * `.default(true)` resolves to; the Host always sends a resolved section, so
     * this only covers the pre-first-acceptance frame.
     *
     * @param field - field name inside the namespace section.
     * @returns the field's conversion spec.
     */
    function settingsBooleanField(field) {
      return {
        field,
        format: (value) => (value === false ? 'false' : 'true'),
        parse: (text) => {
          const trimmed = text.trim()
          if (trimmed === 'true') return { kind: 'set', value: true }
          if (trimmed === 'false') return { kind: 'set', value: false }
          return undefined
        },
      }
    }

    /**
     * Whether the Host holds a value for a `role('secret')` field.
     *
     * The secret's literal never rides the describe response, so presence is the
     * only fact available. It arrives beside the section rather than inside it:
     * `namespace.secrets` carries `{ path, set }` per declared secret position.
     *
     * @param view - the describe view, or undefined before the first answer.
     * @param field - one-segment path of the secret field.
     * @returns whether the Host reports a configured value.
     */
    function secretConfigured(view, field) {
      const namespaces = view === undefined || view === null ? undefined : view.namespaces
      if (!Array.isArray(namespaces)) return false
      const entry = namespaces.find((row) => row.ns === SETTINGS_NAMESPACE)
      const secrets = entry === undefined ? undefined : entry.secrets
      if (!Array.isArray(secrets)) return false
      return secrets.some((secret) => secret.path.length === 1 && secret.path[0] === field && secret.set === true)
    }

    /**
     * A text-area field over a value the settings model stores as JSON.
     *
     * The shipped helpers are `settingsTextField` and `settingsNumberField`, and
     * there is no text-area spec or multi-line control among the primitives
     * (`SettingsValueField` renders a single-line `<input>`). A workspace list is
     * a list, not a scalar, so it needs one — and keeping it a single text field
     * is what lets it stay on the shared form model: the model writes
     * `{op:'set', path:[field], value}` with whatever `parse` returns, which is
     * exactly the object array the Host schema declares.
     *
     * The conversion contract is the shared one: format in, parse out, and an
     * `undefined` parse blocks the save. That is how a mistyped level is caught
     * in the form instead of being silently defaulted in the Host.
     *
     * @param field - field name inside the namespace section.
     * @param format - structured value → text.
     * @param parse - text → structured value, or `undefined` to reject.
     * @returns the field's conversion spec.
     */
    function settingsJsonField(field, format, parse) {
      return {
        field,
        format: (value) => format(value),
        parse: (text) => {
          const trimmed = text.trim()
          if (trimmed === '') return { kind: 'clear' }
          const value = parse(trimmed)
          return value === undefined ? undefined : { kind: 'set', value }
        },
      }
    }

    /**
     * Parse the workspace text-area value into the array the Host schema stores.
     *
     * A copy of `parseWorkspaceListStrict` from `lib/pure.js`, not an import: the
     * browser bundle is loaded through `window.__ModuleLoader__.load` and a
     * relative `require` would be read as a package-local chunk request and fail
     * (see this file's header). The two are kept in step by
     * `test/client.test.js`, which compares them over the same inputs.
     *
     * Returns `undefined` for an unknown level so the shared form model rejects
     * the save instead of writing a value the Host would have to guess at.
     *
     * @param text - the text-area value.
     * @returns the rows, or `undefined` when a level is not recognised.
     */
    function parseWorkspaceText(text) {
      if (text === '') return []
      const out = []
      const seen = new Set()
      for (const raw of text.split('\n')) {
        const line = raw.trim()
        if (line === '' || line.startsWith('#')) continue
        const eq = line.indexOf('=')
        const pathText = eq < 0 ? line : line.slice(0, eq)
        const path = trimTrailingSlash(pathText.trim())
        if (path === '') continue
        const levelText = eq < 0 ? '' : line.slice(eq + 1).trim()
        if (levelText !== '' && !WORKSPACE_LEVELS.includes(levelText)) return undefined
        const level = levelText === '' ? DEFAULT_LEVEL : levelText
        if (seen.has(path)) continue
        seen.add(path)
        out.push({ path, level })
      }
      return out
    }

    /** Trim a hand-typed path the way the Host does, keeping a lone `/`. */
    function trimTrailingSlash(value) {
      if (value === '') return ''
      const stripped = value.replace(/\/+$/, '')
      return stripped === '' ? '/' : stripped
    }

    /**
     * Render the stored array back into the text-area form.
     *
     * @param rows - the structured value from the settings section.
     * @returns one `路径 = 级别` per line.
     */
    function formatWorkspaceRows(rows) {
      if (!Array.isArray(rows)) return ''
      const lines = []
      for (const row of rows) {
        if (row === null || typeof row !== 'object') continue
        const path = trimTrailingSlash(typeof row.path === 'string' ? row.path.trim() : '')
        if (path === '') continue
        const level = WORKSPACE_LEVELS.includes(row.level) ? row.level : DEFAULT_LEVEL
        lines.push(path + ' = ' + level)
      }
      return lines.join('\n')
    }

    /**
     * One multi-line text setting.
     *
     * Grows with its content the way the composer does: a fixed `rows` would
     * either clip a long list or leave a mostly empty box for a short one.
     *
     * @param props.id - input id, so the label can point at it.
     * @param props.label - visible label.
     * @param props.hint - explanation under the control.
     * @param props.value - current staged text.
     * @param props.placeholder - example shown while empty; a list field is
     *   much easier to fill in when its syntax is visible than when it is
     *   described only in the hint.
     * @param props.invalid - whether the staged text fails to parse.
     * @param props.disabled - whether the control refuses input.
     * @param props.onEdit - stages the edited text.
     * @returns the labelled text-area.
     */
    function TextAreaField(props) {
      const ref = react.useRef(null)
      react.useLayoutEffect(() => {
        const node = ref.current
        if (node === null) return undefined
        const resize = () => {
          node.style.height = 'auto'
          node.style.height = `${node.scrollHeight + node.offsetHeight - node.clientHeight}px`
        }
        resize()
        const observer = new ResizeObserver(resize)
        observer.observe(node)
        return () => {
          observer.disconnect()
        }
      }, [props.value])
      return react.createElement(
        'div',
        { style: { display: 'flex', flexDirection: 'column', gap: '6px' } },
        react.createElement('label', { style: labelStyle, htmlFor: props.id }, props.label),
        react.createElement('textarea', {
          id: props.id,
          ref,
          // `rows` only sets the initial box; the layout effect takes over after
          // mount and sizes to content, clamped by minHeight.
          rows: TEXT_AREA_MIN_ROWS,
          value: props.value,
          disabled: props.disabled,
          placeholder: props.placeholder,
          spellCheck: false,
          style: {
            ...textAreaStyle,
            ...(props.invalid ? textAreaInvalidStyle : {}),
          },
          onChange: (event) => props.onEdit(event.target.value),
        }),
        react.createElement('p', { style: props.invalid ? hintInvalidStyle : hintStyle }, props.hint),
      )
    }

    //#endregion field specs

    //#region locales

    /** Simplified Chinese copy. */
    const zh = {
      title: '忆时塔桥接',
      description: '把会话活动自动记入忆时塔（chronomem）。',
      formTitle: '忆时塔桥接配置',
      url: '服务地址',
      urlHint: '忆时塔地址，MCP 端点为 <地址>/mcp。',
      token: '认证 key',
      tokenHint: '写入插件行 config。留空表示保持当前 key；填了才会发送 Authorization: Bearer。',
      tokenSet: '已配置密钥',
      tokenUnset: '未配置密钥',
      enabled: '总开关',
      enabledHint: '关闭后不再写入任何条目。',
      distill: '目标收口蒸馏',
      distillHint: '仅在一个目标（goal）完成时触发，对该会话的塔内活动做一次聚合，产出「做成了什么 / 下一步」。日常问答与闲聊没有目标，不会触发，也不产生任何调用。它与忆时塔按时间窗（今天/本周）的自动总结是两回事：那个按时间切，这个按目标切，互不替代。常用 goal 的话建议开启；不用 goal 可以关掉。',
      fullContext: '全上下文工作区',
      fullContextHint: '一行一个：路径 = 级别（级别可省略，默认 names）。级别 none=只存对话、names=存工具名与一行摘要、full=存工具入参出参。留空则所有会话都按默认方式记录（每轮只存末条回复）。',
      // 示例直接写在框里：列表字段的语法只在 hint 里描述时，用户得先照着拼一遍才敢填。
      fullContextPlaceholder: '/home/me/notes = none\n/home/me/notes/code = full\njournal = names',
      fullContextInvalid: '有行的级别写错了，只接受 none / names / full。',
      privacy: '开启后会向忆时塔上报：轮次末条回复、dsh 已产生的压缩摘要，以及事件自带的标量字段。全上下文工作区还会额外上报你输入的消息（仅真人输入，不含注入内容）与按级别的工具调用。',
      overridden: '已覆盖',
      reset: '恢复默认',
      invalidText: '该值无效，保存已被阻止。',
      readOnly: '本部署的设置为只读。',
      unavailable: '该插件当前未加载，暂时无法配置。',
      save: '保存',
      saving: '保存中…',
      saveFailed: '本部署没有接受这些值，已保留供你修改。',
    }

    /** English copy. */
    const en = {
      title: 'Memory bridge',
      description: 'Records session activity into 忆时塔 (chronomem) automatically.',
      formTitle: 'Memory bridge settings',
      url: 'Service URL',
      urlHint: 'Address of 忆时塔; its MCP endpoint is <url>/mcp.',
      token: 'Auth key',
      tokenHint: 'Stored in the plugin row config. Leave blank to keep the current key; when set, requests carry Authorization: Bearer.',
      tokenSet: 'Key configured',
      tokenUnset: 'No key configured',
      enabled: 'Enabled',
      enabledHint: 'When off, no entry is written at all.',
      distill: 'Goal close-out distillation',
      distillHint: 'Runs only when a goal completes, aggregating that session into \'what was achieved / what is next\'. Everyday Q&A and chat have no goal, so it never runs and costs nothing there. This is not the same as the tower\'s time-window summaries (today/this week): those cut by time, this cuts by goal. Turn it on if you use goals often; off is fine otherwise.',
      fullContext: 'Full-context workspaces',
      fullContextHint: 'One per line: path = level (level defaults to names). none keeps the conversation only, names keeps tool names plus a one-line summary, full keeps tool arguments and output. Empty means every session records the default way (final reply per turn).',
      fullContextPlaceholder: '/home/me/notes = none\n/home/me/notes/code = full\njournal = names',
      fullContextInvalid: 'A line has an unknown level; only none / names / full are accepted.',
      privacy: 'When on, this uploads the final reply of each turn, the compaction summary dsh produced, and event-borne scalar fields to 忆时塔. A full-context workspace additionally uploads the messages you typed (human input only, never injected context) and tool calls at its configured level.',
      overridden: 'Overridden',
      reset: 'Reset to default',
      invalidText: 'This value is not accepted, so the save is blocked.',
      readOnly: 'This deployment stores settings read-only.',
      unavailable: 'This plugin is not loaded, so it cannot be configured right now.',
      save: 'Save',
      saving: 'Saving…',
      saveFailed: 'The deployment did not accept these values; they were left for you to correct.',
    }

    //#endregion locales

    //#region controls

    /** Token-ish styling, so the switch row reads like the shared value fields. */
    const labelStyle = {
      fontSize: '12px',
      fontWeight: 500,
      lineHeight: '18px',
      color: 'var(--dsw-alias-label-secondary)',
    }
    const hintStyle = {
      margin: 0,
      fontSize: '12px',
      lineHeight: '18px',
      color: 'var(--dsw-alias-label-tertiary)',
    }
    /** The text-area mirrors the shared input's metrics so the form stays aligned. */
    /** Minimum height, in content lines: an empty box still reads as "a list goes here". */
    const TEXT_AREA_MIN_ROWS = 4
    const textAreaStyle = {
      boxSizing: 'border-box',
      width: '100%',
      resize: 'none',
      // `overflow: hidden` + auto-height: the field grows with its content and
      // never shows its own scrollbar. It is a settings list, not an editor.
      overflow: 'hidden',
      // A collapsed textarea reads as a one-line input, which hides the fact
      // that it takes several entries at all — so hold a minimum instead.
      minHeight: `${TEXT_AREA_MIN_ROWS * 20 + 12}px`,
      border: '0.5px solid var(--dsw-alias-border-l4)',
      borderRadius: 'var(--dsw-radius-md)',
      background: 'var(--dsw-alias-bg-layer-1)',
      color: 'var(--dsw-alias-label-primary)',
      padding: '6px 10px',
      fontFamily: 'var(--ds-font-family-code)',
      fontSize: '13px',
      lineHeight: '20px',
    }
    const textAreaInvalidStyle = { borderColor: 'var(--dsw-alias-state-error-primary)' }
    const hintInvalidStyle = {
      margin: 0,
      fontSize: '12px',
      lineHeight: '18px',
      color: 'var(--dsw-alias-state-error-primary)',
    }

    /**
     * One boolean setting: a visible label, the switch, and its hint.
     *
     * The switch's accessible name is its own `label` prop, so the visible text
     * is decorative here and carries no id — nothing associates it with the
     * control, which is a button rather than a labelled input.
     *
     * @param props.label - visible label text, also the switch's accessible name.
     * @param props.hint - one-line explanation under the row.
     * @param props.checked - current staged state.
     * @param props.disabled - whether the control refuses input.
     * @param props.onToggle - stages the requested state.
     * @returns the labelled switch row.
     */
    function BooleanField(props) {
      return react.createElement(
        'div',
        { style: { display: 'flex', flexDirection: 'column', gap: '6px' } },
        react.createElement(
          'div',
          { style: { display: 'flex', alignItems: 'center', gap: '10px' } },
          react.createElement('span', { style: labelStyle }, props.label),
          react.createElement(primitives.Switch, {
            checked: props.checked,
            label: props.label,
            disabled: props.disabled,
            onChange: props.onToggle,
          }),
        ),
        react.createElement('p', { style: hintStyle }, props.hint),
      )
    }

    /**
     * Render the plugin's row page: the one-liner the row falls back to, or the
     * four settings the Host exposes.
     *
     * @param props.view - `summary` renders the one-liner; `page` renders the form.
     * @param props.t - locale reader bound to this page's dictionary.
     * @param props.useMemBridge - selector hook over the controller's snapshot.
     * @param props.edit - stage draft text for one field.
     * @param props.resetField - stage a clear for one field.
     * @param props.save - write every staged edit.
     * @param props.discard - drop every staged edit.
     * @returns the one-liner, or the settings form.
     */
    function MemBridgeCard(props) {
      const { t } = props
      const state = props.useMemBridge((snapshot) => snapshot)
      if (props.view === 'summary') return t('description')
      const disabled = !state.writable
      return react.createElement(
        primitives.SettingsForm,
        {
          labels: {
            unavailable: t('unavailable'),
            readOnly: t('readOnly'),
            saveFailed: t('saveFailed'),
            save: t('save'),
            saving: t('saving'),
          },
          state,
          onSave: props.save,
          onDiscard: props.discard,
        },
        react.createElement(primitives.SettingsValueField, {
          id: 'plugin-config-mem-bridge-url',
          label: t('url'),
          hint: t('urlHint'),
          overriddenLabel: t('overridden'),
          resetLabel: t('reset'),
          invalidLabel: t('invalidText'),
          disabled,
          ...state.url,
          onEdit: (text) => props.edit('url', text),
          onReset: () => props.resetField('url'),
        }),
        react.createElement(primitives.SettingsSecretField, {
          id: 'plugin-config-mem-bridge-token',
          label: t('token'),
          hint: t('tokenHint'),
          disabled,
          text: state.token.text,
          configured: state.tokenConfigured,
          stateLabel: state.tokenConfigured ? t('tokenSet') : t('tokenUnset'),
          onEdit: (text) => props.edit(TOKEN_FIELD, text),
        }),
        react.createElement(BooleanField, {
          label: t('enabled'),
          hint: t('enabledHint'),
          checked: state.enabled.text === 'true',
          disabled,
          onToggle: (next) => props.edit('enabled', next ? 'true' : 'false'),
        }),
        react.createElement(BooleanField, {
          label: t('distill'),
          hint: t('distillHint'),
          checked: state.distill.text === 'true',
          disabled,
          onToggle: (next) => props.edit('distill', next ? 'true' : 'false'),
        }),
        react.createElement(TextAreaField, {
          id: 'plugin-config-mem-bridge-full-context',
          label: t('fullContext'),
          placeholder: t('fullContextPlaceholder'),
          hint: state.fullContext.invalid ? t('fullContextInvalid') : t('fullContextHint'),
          value: state.fullContext.text,
          invalid: state.fullContext.invalid,
          disabled,
          onEdit: (text) => props.edit(FULL_CONTEXT_FIELD, text),
        }),
        react.createElement('p', { style: hintStyle }, t('privacy')),
      )
    }

    //#endregion controls

    //#region controller

    /**
     * The row page's staged form over the `mem-bridge` settings namespace.
     *
     * The section fields (url / enabled / distill) go through the shared form
     * model. `token` does not: its literal is absent from every describe
     * response, so it is registered as a write-only control whose write is a
     * plain `set` on the section path — still staged with the rest of the form,
     * so one save covers all four.
     */
    class MemBridgeCardController {
      /**
       * @param scope - the shared configuration form for this namespace.
       * @param describeFace - the shared describe mirror, read for secret presence.
       */
      constructor(scope, describeFace) {
        this.scope = scope
        this.describeFace = describeFace
        this.form = new primitives.SettingsFormModel(
          scope,
          [
            primitives.settingsTextField('url'),
            settingsBooleanField('enabled'),
            settingsBooleanField('distill'),
            settingsJsonField(FULL_CONTEXT_FIELD, formatWorkspaceRows, parseWorkspaceText),
          ],
          [{ field: TOKEN_FIELD, write: (text) => this.writeToken(text) }],
        )
        this.actions = this.form.actions()
        this.store = this.form.bind(() => this.projection())
        this.unsubscribe = describeFace.subscribe(() => {
          this.store.set(this.projection())
        })
      }

      /** @returns the page snapshot: the shared shell, the four fields, and secret presence. */
      projection() {
        return {
          ...this.form.shell(),
          url: this.form.field('url'),
          token: this.form.field(TOKEN_FIELD),
          enabled: this.form.field('enabled'),
          distill: this.form.field('distill'),
          fullContext: this.form.field(FULL_CONTEXT_FIELD),
          tokenConfigured: secretConfigured(this.describeFace.getSnapshot().view, TOKEN_FIELD),
        }
      }

      /**
       * Write the staged token into the section.
       *
       * An empty draft never reaches here (the shared model drops it), which is
       * what preserves a stored key the user did not retype.
       *
       * @param text - the staged credential literal.
       * @returns whether the Host accepted the write.
       */
      writeToken(text) {
        return this.scope.mutate([{ op: 'set', path: [TOKEN_FIELD], value: text }])
      }

      /** @returns the face the slot registration injects. */
      inject() {
        return {
          hooks: { memBridge: this.store },
          ...this.actions,
        }
      }

      /** Release the form's accepted-value subscription. */
      dispose() {
        this.unsubscribe()
        this.form.dispose()
      }
    }

    //#endregion controller

    //#region plugin

    /** Required services: the slot registry, this page's dictionaries, and the shared configuration forms. */
    const inject = ['slots', 'locale', 'configForms']

    /**
     * Mount the configuration page for as long as the Host serves the namespace.
     *
     * The registration follows the namespace, so a deployment that never mounts
     * the plugin shows no trace of the page.
     *
     * @param ctx - the browser plugin context.
     */
    function apply(ctx) {
      const t = ctx.locale.bind(NS)
      ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'dsh-mem-bridge: dictionaries')
      const controller = new MemBridgeCardController(ctx.configForms.get(SETTINGS_NAMESPACE), ctx.configForms.describe())
      ctx.effect(() => () => {
        controller.dispose()
      }, 'dsh-mem-bridge: form subscription')
      ctx.effect(
        () =>
          ctx.configForms.whileServed([SETTINGS_NAMESPACE], () =>
            ctx.slots.inject('plugins.row.config', () =>
              ctx.slots.register(
                {
                  name: 'plugins.row.config',
                  key: ROW_CONFIG_KEY,
                  locale: NS,
                  inject: () => controller.inject(),
                },
                MemBridgeCard,
              ),
            ),
          ),
        'dsh-mem-bridge: configuration page',
      )
    }

    //#endregion plugin

    exports.apply = apply
    exports.inject = inject
    // Exported for the unit tests that pin this bundle's contract.
    exports.NS = NS
    // Dictionaries, so a test can assert the example shipped in the UI is itself
    // valid input (the render path only sees translation keys).
    exports.dictionaries = { zh, en }
    exports.SETTINGS_NAMESPACE = SETTINGS_NAMESPACE
    exports.ROW_CONFIG_KEY = ROW_CONFIG_KEY
    exports.TOKEN_FIELD = TOKEN_FIELD
    exports.FULL_CONTEXT_FIELD = FULL_CONTEXT_FIELD
    exports.settingsJsonField = settingsJsonField
    exports.TextAreaField = TextAreaField
    exports.settingsBooleanField = settingsBooleanField
    // Exported for the unit tests that pin this bundle's parsing against pure.js.
    exports.parseWorkspaceText = parseWorkspaceText
    exports.formatWorkspaceRows = formatWorkspaceRows
    exports.secretConfigured = secretConfigured
    exports.MemBridgeCardController = MemBridgeCardController
    exports.MemBridgeCard = MemBridgeCard
    return module.exports
  },
})
