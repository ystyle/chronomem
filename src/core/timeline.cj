package chronomem.core

import cron.*
import tsdb.*
import std.collection.*
import std.sync.Mutex
import std.time.*

// 通用分层时间线：一个 tsdb series 的 append-only 时序记录 + 分层物化桶链。
// 从 liveboard.core.Timeline 泛化：
//  - 粒度链（levels）改为每 series 配置（design.md §5.1），非全局写死；
//  - 不耦合 atelier.message（payload 一律字符串载体）；
//  - 新增 listBuckets（mem/buckets 发现窗口用）；
//  - **自然时间窗口（日历对齐，design.md §5.2）**：10min/30min/1h/3h 钟表对齐；
//    day/week/month 按本地日历（日=本地零点、周=周一起点、月=1 号零点）对齐，非 epoch 锚定。
// 数据归属 TimelineStore（共享同一 tsdb）；Timeline 是非持有句柄（close 走 store）。
public class Timeline {
    private let tsdb: Tsdb
    private let series: String
    private let levels: ArrayList<String>
    private let timeZone: TimeZone

    public init(tsdb: Tsdb, series: String, levels: ArrayList<String>, timeZone: TimeZone) {
        this.tsdb = tsdb
        this.series = series
        this.levels = levels
        this.timeZone = timeZone
    }

    public func seriesName(): String { this.series }
    public func levelsOf(): ArrayList<String> { this.levels }

    // ---------- 静态：粒度集 / 校验 / 名义窗口 ----------

    // 允许粒度集（§5.1）：10min/30min/1h/3h/day/week/month
    public static func allowedLevels(): ArrayList<String> {
        let l = ArrayList<String>()
        l.add("10min")
        l.add("30min")
        l.add("1h")
        l.add("3h")
        l.add("day")
        l.add("week")
        l.add("month")
        l
    }

    // 默认链（§5.1）：10min → 30min → 1h → day → week（week 为默认语义总结封顶）
    public static func defaultLevels(): ArrayList<String> {
        let l = ArrayList<String>()
        l.add("10min")
        l.add("30min")
        l.add("1h")
        l.add("day")
        l.add("week")
        l
    }

    // 名义窗口毫秒（钟表对齐粒度用精确值；day/week/month 为名义值，实际窗口按日历对齐计算）
    public static func windowMs(level: String): Int64 {
        match (level) {
            case "10min" => 10 * 60 * 1000
            case "30min" => 30 * 60 * 1000
            case "1h" => 60 * 60 * 1000
            case "3h" => 3 * 60 * 60 * 1000
            case "day" => 24 * 60 * 60 * 1000
            case "week" => 7 * 24 * 60 * 60 * 1000
            case "month" => 30 * 24 * 60 * 60 * 1000
            case _ => 0
        }
    }

    // 校验粒度链：全部在允许集内、严格升序（按名义窗口毫秒）、无重复、至少 1 档。非法抛异常。
    public static func validateLevels(levels: ArrayList<String>): Unit {
        if (levels.size == 0) {
            throw Exception("levels 不能为空")
        }
        var prev: Int64 = 0
        for (l in levels) {
            let w = Timeline.windowMs(l)
            if (w <= 0) {
                throw Exception("非法粒度: " + l + "（允许: 10min/30min/1h/3h/day/week/month）")
            }
            if (w <= prev) {
                throw Exception("levels 须严格升序且无重复: " + l)
            }
            prev = w
        }
    }

    // 取粒度链最粗 n 档（自动语义总结目标粒度缺省值，§7.3）
    public static func coarsestLevels(levels: ArrayList<String>, n: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        var i = levels.size - 1
        var taken = Int64(0)
        while (i >= 0 && taken < n) {
            out.add(levels[Int64(i)])
            i -= 1
            taken += 1
        }
        // 反转成升序
        let sorted = ArrayList<String>()
        var j = out.size - 1
        while (j >= 0) {
            sorted.add(out[Int64(j)])
            j -= 1
        }
        sorted
    }

    // ---------- 自然时间窗口（日历对齐，§5.2） ----------

    // ts 所在窗口的起点（毫秒）
    public func windowStartOf(ts: Int64, level: String): Int64 {
        let w = Timeline.windowMs(level)
        if (w <= 0) {
            throw Exception("非法粒度: " + level)
        }
        match (level) {
            case "day" | "week" | "month" =>
                this.calendarStartMs(this.dateTimeOf(ts), level)
            case _ =>
                ts - (ts % w)
        }
    }

    // start 所在窗口的下一窗口起点（毫秒）；day/week/month 按日历计算（正确处理 DST/大小月）
    public func nextWindowStartMs(start: Int64, level: String): Int64 {
        let w = Timeline.windowMs(level)
        if (w <= 0) {
            throw Exception("非法粒度: " + level)
        }
        match (level) {
            case "day" =>
                this.dateTimeOf(start).addDays(1).toUnixTimeStamp().toMilliseconds()
            case "week" =>
                this.dateTimeOf(start).addDays(7).toUnixTimeStamp().toMilliseconds()
            case "month" =>
                this.dateTimeOf(start).addMonths(1).toUnixTimeStamp().toMilliseconds()
            case _ =>
                start + w
        }
    }

    // 桶 key：窗口起点按 UTC ISO 编码（与 tsdb.bucketKeyOf 同格式，可排序、对 tsdb 透明）
    public func windowKeyOf(ts: Int64, level: String): String {
        this.formatUtcIso(this.windowStartOf(ts, level))
    }

    // 窗口 [start, end]（end = 下一窗口起点 - 1）
    public func windowRangeOf(ts: Int64, level: String): (Int64, Int64) {
        let start = this.windowStartOf(ts, level)
        let end = this.nextWindowStartMs(start, level) - 1
        (start, end)
    }

    private func dateTimeOf(ms: Int64): DateTime {
        DateTime.ofEpoch(second: ms / 1000, nanosecond: (ms % 1000) * 1000000).inTimeZone(this.timeZone)
    }

    private func calendarStartMs(dt: DateTime, level: String): Int64 {
        let (y, m, d) = dt.date
        match (level) {
            case "day" =>
                DateTime.of(year: y, month: m, dayOfMonth: d, timeZone: this.timeZone)
                    .toUnixTimeStamp().toMilliseconds()
            case "week" =>
                // 周一起点（ISO8601 习惯；周一=0 … 周日=6）
                let offset = dayOfWeekOffset(dt.dayOfWeek)
                let monday = dt.addDays(-offset)
                let (my, mm, md) = monday.date
                DateTime.of(year: my, month: mm, dayOfMonth: md, timeZone: this.timeZone)
                    .toUnixTimeStamp().toMilliseconds()
            case "month" =>
                DateTime.of(year: y, month: m, dayOfMonth: 1, timeZone: this.timeZone)
                    .toUnixTimeStamp().toMilliseconds()
            case _ =>
                DateTime.of(year: y, month: m, dayOfMonth: d, timeZone: this.timeZone)
                    .toUnixTimeStamp().toMilliseconds()
        }
    }

    private func formatUtcIso(ms: Int64): String {
        let dt = DateTime.ofEpoch(second: ms / 1000, nanosecond: (ms % 1000) * 1000000).inUTC()
        dt.format("yyyy-MM-dd") + "T" + dt.format("HH:mm:ss") + "Z"
    }

    // ---------- 写入 ----------

    public func append(ts: Int64, payload: String, tags: HashMap<String, String>): Unit {
        this.tsdb.append(this.series, ts, payload, tags)
    }

    // ---------- 查询（读，不落盘） ----------

    // 时间范围（from/to = 0 表示不设边界）+ limit（最新在前；0 = 全部）+ 标签过滤（可选）
    public func queryPoints(from: Int64, to: Int64, limit: Int64, tagFilter: Option<(String, String)>): ArrayList<Point> {
        var q = this.tsdb.query(this.series).reverse()
        if (from > 0 || to > 0) {
            q = q.range(from, if (to > 0) { to } else { Int64.Max })
        }
        if (let Some((tag, value)) <- tagFilter) {
            q = q.filter(tag, value)
        }
        if (limit > 0) {
            q = q.limit(limit)
        }
        q.find()
    }

    // 页码分页查询：返回 (本页点, 总数)。page 从 1 起；pageSize 为每页条数。
    // count 全量（key-only/索引）一次 + offset 下推取本页——不做全量内存切片，
    // 大条目量时无 payload 峰值（配合 tsdb Query.offset/timestamps 语义）。
    public func queryPointsPage(from: Int64, to: Int64, page: Int64, pageSize: Int64,
        tagFilter: Option<(String, String)>): (ArrayList<Point>, Int64) {
        let size = if (pageSize > 0) { pageSize } else { 20 }
        let p = if (page > 0) { page } else { 1 }
        var q = this.tsdb.query(this.series).reverse()
        if (from > 0 || to > 0) {
            q = q.range(from, if (to > 0) { to } else { Int64.Max })
        }
        if (let Some((tag, value)) <- tagFilter) {
            q = q.filter(tag, value)
        }
        let total = q.count()
        let points = q.offset((p - 1) * size).limit(size).find()
        (points, total)
    }

    // 窗口内全部 ts（ts-only 扫描，不读 payload）——物化/补齐引用链用
    public func windowTimestamps(from: Int64, to: Int64): ArrayList<Int64> {
        this.tsdb.query(this.series).range(from, to).timestamps()
    }

    // 分批遍历窗口内全部点（keyset 游标翻页）：每批 ≤ batchSize 条，回调后即弃
    // ——边读边拼原语：summarize/物化等场景避免整窗 ArrayList<Point> 驻留，
    // 大窗口 + 大 payload 时内存峰值从 O(窗口字节) 降到 O(单批字节)。
    // 窗口为空时不回调，返回 false。
    public func forEachWindowPoint(from: Int64, to: Int64, batchSize: Int64,
        fn: (ArrayList<Point>) -> Unit): Bool {
        let batch = if (batchSize > 0) { batchSize } else { 200 }
        var afterTs: Int64 = -1
        var afterSeq: Int64 = -1
        var any = false
        let q = this.tsdb.query(this.series).range(from, to).reverse()
        while (true) {
            let page = if (afterTs >= 0) {
                q.findPage(afterTs: afterTs, afterSeq: afterSeq, limit: batch)
            } else {
                q.findPage(limit: batch)
            }
            if (page.items.size == 0) { break }
            any = true
            fn(page.items)
            if (!page.hasMore()) { break }
            afterTs = page.nextTs
            afterSeq = page.nextSeq
        }
        any
    }

    public func count(): Int64 {
        this.tsdb.query(this.series).count()
    }

    // 时间范围内条目数（key-only 计数，不读 payload——空窗口判定用）
    public func countIn(from: Int64, to: Int64): Int64 {
        this.tsdb.query(this.series).range(from, to).count()
    }

    // ---------- 删除（TRUNCATE / DROP，委托 tsdb） ----------

    // TRUNCATE：清空本系列全部数据（点/索引/桶），保留系列
    public func clearAll(): Int64 {
        this.tsdb.clearSeries(this.series)
    }

    // DROP：彻底删除本系列（数据 + meta + 标签索引）
    public func deleteAll(): Unit {
        this.tsdb.deleteSeries(this.series)
    }

    // ---------- 分层物化（幂等覆盖，每层落盘不删下层） ----------

    // 物化 ts 所在时间窗口的分层桶链（按本 series 的 levels）：
    // 最细层（当前窗口内全部点 → PointRef）→ 逐层向上（当前窗口内已存在的下一层子桶 → BucketRef）。
    // 空窗口不建桶；label 用于桶摘要文案（如「对话」「工具调用」）。
    public func materialize(ts: Int64, label: String): Unit {
        let levels = this.levels
        // 最细层
        let fStart = this.windowStartOf(ts, levels[0])
        let fEnd = this.nextWindowStartMs(fStart, levels[0]) - 1
        let fKey = this.windowKeyOf(ts, levels[0])
        // ts-only 扫描：物化只需窗口内点的 ts 建 PointRef，payload 零读取
        // （此前 range().find() 把整窗 payload 全量 decode——分钟级 cron 全量读
        // 是长跑内存峰值主源；timestamps() 只解析 key 的 ts）
        let winTs = this.tsdb.query(this.series).range(fStart, fEnd).timestamps()
        // 日志瘦身：空窗口静默（原每窗口一行，30 窗口×4 series/轮 = 120+ 行刷屏，
        // 字符串分配累积 GC 堆压力）；仅在有数据/建桶时输出一行。
        if (winTs.size > 0) {
            println("materialize " + this.series + " finer=" + levels[0] + " fStart=" + fStart.toString() + " fEnd=" + fEnd.toString() + " pts=" + winTs.size.toString())
            let refs = ArrayList<Ref>()
            for (t in winTs) { refs.add(Ref.PointRef(this.series, t)) }
            this.tsdb.bucket(this.series, levels[0], fKey,
                levels[0] + " 窗口" + label + " " + winTs.size.toString() + " 条", refs,
                ttl: None, windowStartMs: fStart, windowEndMs: fEnd)
        }
        // 逐层向上：当前窗口内已存在的下一层子桶 → BucketRef
        for (i in 1..levels.size) {
            let level = levels[i]
            let finer = levels[i - 1]
            let start = this.windowStartOf(ts, level)
            let end = this.nextWindowStartMs(start, level) - 1
            let key = this.windowKeyOf(ts, level)
            let refs = ArrayList<Ref>()
            var sub = start
            while (sub <= end) {
                let subStart = this.windowStartOf(sub, finer)
                let subKey = this.windowKeyOf(subStart, finer)
                if (this.tsdb.bucketSummary(this.series, finer, subKey).isSome()) {
                    refs.add(Ref.BucketRef(this.series, finer, subKey))
                }
                sub = this.nextWindowStartMs(subStart, finer)
            }
            if (refs.size > 0) {
                this.tsdb.bucket(this.series, level, key,
                    level + " 窗口覆盖 " + refs.size.toString() + " 个 " + finer + " 子桶", refs,
                    ttl: None, windowStartMs: start, windowEndMs: end)
            }
        }
    }

    // 补齐最近 backWindows 个已闭合窗口缺失的桶（重启恢复/数据回填）：
    // - 只补「最细层桶不存在」的已闭合窗口（幂等：已有桶跳过，不重写）；
    // - 当窗沿用 materialize 原语义（每次物化）；
    // - 服务重启后历史桶不再依赖「当窗才物化」（否则重启即丢历史桶，UI 塔视图空白）。
    public func materializeMissingClosed(now: Int64, label: String, backWindows: Int64): Unit {
        let finest = this.levels[0]
        // 候选锚点（窗口起点）：当窗 + 最近 backWindows 个历史窗口；起点 - 1ms 必落上一窗口
        let anchors = ArrayList<Int64>()
        var anchor = this.windowStartOf(now, finest)
        anchors.add(anchor)
        for (i in 0..backWindows) {
            anchor = this.windowStartOf(anchor - 1, finest)
            anchors.add(anchor)
        }
        // 从旧到新补物化（下层桶先行，上层 chain 依赖子桶存在）
        var idx = anchors.size - 1
        while (idx >= 0) {
            let ts = anchors[Int64(idx)]
            idx -= 1
            let key = this.windowKeyOf(ts, finest)
            if (this.tsdb.bucketSummary(this.series, finest, key).isSome()) {
                continue
            }
            let end = this.nextWindowStartMs(ts, finest) - 1
            if (end >= now) {
                continue   // 未闭合窗口不补（当窗由下方 materialize(now) 处理）
            }
            this.materialize(ts, label)
        }
        // 当窗物化（原调度语义）
        this.materialize(now, label)
    }

    // ---------- 精确回想：沿分层桶下钻到原始点 ----------

    public func drillDown(granularity: String, bucketKey: String): ArrayList<Point> {
        let result = ArrayList<Point>()
        this.resolveRefs(this.tsdb.drillDown(this.series, granularity, bucketKey), result)
        result
    }

    // 批量解析（性能关键）：同一系列的点引用聚合成窗口一次 range 查询（badger 单点 get 慢，
    // 桶内 27 点逐点查询在容器卷上 ~秒级；批量一次查询毫秒级）。BucketRef 递归逐层。
    private func resolveRefs(refs: ArrayList<Ref>, out: ArrayList<Point>): Unit {
        // 先按 series 聚合 PointRef 的 ts 区间
        let bySeries = HashMap<String, (Int64, Int64)>()
        for (r in refs) {
            match (r) {
                case Ref.PointRef(s, t) =>
                    match (bySeries.get(s)) {
                        case Some((lo, hi)) => bySeries[s] = (if (lo < t) { lo } else { t }, if (hi > t) { hi } else { t })
                        case None => bySeries[s] = (t, t)
                    }
                case _ => ()
            }
        }
        for ((s, win) in bySeries) {
            let pts = this.tsdb.query(s).range(win[0], win[1]).find()
            for (p in pts) { out.add(p) }
        }
        // BucketRef（聚合层下钻）单独递归
        for (r in refs) {
            match (r) {
                case Ref.BucketRef(s, l, k) =>
                    this.resolveRefs(this.tsdb.drillDown(s, l, k), out)
                case _ => ()
            }
        }
    }

    // ---------- 桶信息（mem/buckets 发现窗口用） ----------

    public func bucketSummary(granularity: String, bucketKey: String): Option<String> {
        match (this.tsdb.bucketSummary(this.series, granularity, bucketKey)) {
            case Some(rec) => Some(rec.summary)
            case None => None
        }
    }

    public func listBuckets(granularity: String, from: Option<String>, to: Option<String>): ArrayList<BucketRecord> {
        this.tsdb.listBuckets(this.series, granularity, from, to)
    }

    // 轻量桶列表（不构造 refs 对象数组；UI 塔层/桶卡片统计走这里，防 GC 堆膨胀）
    public func listBucketMetas(granularity: String, from: Option<String>, to: Option<String>): ArrayList<BucketMeta> {
        this.tsdb.listBucketMetas(this.series, granularity, from, to)
    }

    // 某粒度下「覆盖 anchor」的物化桶键；anchor 所在桶未物化时回退到最近的更早桶
    public func bucketAt(granularity: String, anchor: Int64): Option<String> {
        let key = this.windowKeyOf(anchor, granularity)
        if (this.tsdb.bucketSummary(this.series, granularity, key).isSome()) {
            return Some(key)
        }
        let buckets = this.tsdb.listBuckets(this.series, granularity, None, Some(key))
        var latest: Option<String> = None
        for (b in buckets) { latest = Some(b.bucketKey) }
        latest
    }
}

// DayOfWeek → 周一偏移（Mon=0, Tue=1, …, Sun=6）
func dayOfWeekOffset(d: DayOfWeek): Int64 {
    match (d) {
        case DayOfWeek.Monday => 0
        case DayOfWeek.Tuesday => 1
        case DayOfWeek.Wednesday => 2
        case DayOfWeek.Thursday => 3
        case DayOfWeek.Friday => 4
        case DayOfWeek.Saturday => 5
        case DayOfWeek.Sunday => 6
        case _ => 0
    }
}

// 分层时间线共享容器：一个 tsdb 实例承载多个 series（<type> 与 <type>.summary）。
// 每 series 带 label（物化桶摘要文案）、levels（粒度链，§5.1）与统一时区（自然窗口，§5.2）。
// 注册的 series 由 MaterializeScheduler 统一分层物化（定时推进，不依赖事件发生）。
public class TimelineStore {
    private let tsdb: Tsdb
    private let timeZone: TimeZone
    private let seriesLabels = HashMap<String, String>()
    private let seriesLevels = HashMap<String, ArrayList<String>>()
    // 并发保护：物化线程（cron）与 MCP 接收循环/后台总结线程可并发访问 series 注册表。
    private let mapLock = Mutex()

    // syncWrites=true：每次 append 同步落盘（badger fsync），容器/进程被 SIGTERM/SIGKILL 也不丢数据
    public static func open(path: String, timeZone!: TimeZone = TimeZone.Local,
        syncWrites!: Bool = false, memTableSize!: UInt64 = 16 * 1024 * 1024u64): TimelineStore {
        TimelineStore(Tsdb.open(path, memTableSize: memTableSize, syncWrites: syncWrites), timeZone)
    }

    public static func openInMemory(timeZone!: TimeZone = TimeZone.Local): TimelineStore {
        TimelineStore(Tsdb.openInMemory(), timeZone)
    }

    private init(tsdb: Tsdb, timeZone: TimeZone) {
        this.tsdb = tsdb
        this.timeZone = timeZone
    }

    public func close(): Unit { this.tsdb.close() }
    public func isClosed(): Bool { this.tsdb.isClosed() }

    // 底层 tsdb（注册表等需要直接读写 meta / count 用）
    public func rawTsdb(): Tsdb { this.tsdb }

    // 自然时间窗口时区（§5.2；调度器 cron 墙钟对齐用）
    public func timeZoneOf(): TimeZone { this.timeZone }

    // 取某 series 的句柄（共享同一 tsdb；句柄不持有所有权，close 走 store）；
    // label 用于物化桶摘要文案；levels 为该 series 的粒度链。
    public func timeline(series: String, label: String, levels: ArrayList<String>): Timeline {
        synchronized(this.mapLock) {
            this.seriesLabels[series] = label
            this.seriesLevels[series] = levels
        }
        Timeline(this.tsdb, series, levels, this.timeZone)
    }

    // 全部已注册 series 统一分层物化（MaterializeScheduler 每 60s 调用；幂等、空窗口零成本）。
    // backWindows > 0：同时补齐最近 backWindows 个已闭合窗口缺失的桶（重启恢复历史桶，§8.6）。
    public func materializeAll(now: Int64, backWindows!: Int64 = 0): Unit {
        // 快照复制在锁内（毫秒级），物化在锁外（避免长临界区阻塞 type_create 等）
        let snapshot = synchronized(this.mapLock) {
            let l = ArrayList<(String, String, ArrayList<String>)>()
            for ((series, label) in this.seriesLabels) {
                match (this.seriesLevels.get(series)) {
                    case Some(levels) => l.add((series, label, levels))
                    case None => ()
                }
            }
            l
        }
        for ((series, label, levels) in snapshot) {
            println("materializeAll series=" + series + " levels=" + levels.toString())
            let tl = Timeline(this.tsdb, series, levels, this.timeZone)
            if (backWindows > 0) {
                tl.materializeMissingClosed(now, label, backWindows)
            } else {
                tl.materialize(now, label)
            }
        }
    }
}

// 定时分层物化（cron-cj 后台调度，默认 @every 1m）：幂等、空窗口零成本。
// 只做结构物化（引用链桶），零 LLM 成本；语义摘要不自动物化（见 design.md §7.3）。
public class MaterializeScheduler {
    private let store: TimelineStore
    private var cron: Option<Cron> = None

    public init(store: TimelineStore) {
        this.store = store
    }

    // 单次物化（cron 触发与测试共用）：当窗 + 最近 30 个已闭合窗口缺失桶补齐（重启恢复历史桶）
    public func materializeNow(): Unit {
        println("chronomem materializeNow start: " + nowMs().toString())
        this.store.materializeAll(nowMs(), backWindows: 30)
        println("chronomem materializeNow done")
    }

    // 启动后台周期物化（cron 表达式或 @every <duration>，缺省 @every 1m；与结构物化时区对齐）
    public func start(spec!: String = "@every 1m"): Unit {
        let c = Cron()
        c.setLocation(this.store.timeZoneOf())
        addCronEntry(c, spec, { => this.materializeNow() })
        c.start()
        this.cron = Some(c)
    }

    public func stop(): Unit {
        match (this.cron) {
            case Some(c) => c.stop()
            case None => ()
        }
    }
}

// 当前时间戳（毫秒）
public func nowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

// cron 任务注册辅助：支持 `@every <duration>`（→ ConstantDelaySchedule，间隔调度）
// 与标准 cron 表达式（→ 墙钟调度）。cron-cj 的 addFunc 不解析 @every 描述符，需走 addSchedule。
public func addCronEntry(c: Cron, spec: String, cmd: () -> Unit): Unit {
    if (spec.startsWith("@every ")) {
        c.addSchedule(Every(spec[7..]), FuncJob(cmd))
    } else {
        c.addFunc(spec, cmd)
    }
}
