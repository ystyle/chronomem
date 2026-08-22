package chronomem.core

import tsdb.*
import std.collection.*
import std.core.{Duration, sleep}
import std.time.*

// 通用分层时间线：一个 tsdb series 的 append-only 时序记录 + 分层物化桶链。
// 从 liveboard.core.Timeline 泛化：
//  - 粒度链（levels）改为每 series 配置（design.md §5.1），非全局写死；
//  - 不耦合 atelier.message（payload 一律字符串载体）；
//  - 新增 listBuckets（mem/buckets 发现窗口用）。
// 数据归属 TimelineStore（共享同一 tsdb）；Timeline 是非持有句柄（close 走 store）。
public class Timeline {
    private let tsdb: Tsdb
    private let series: String
    private let levels: ArrayList<String>

    public init(tsdb: Tsdb, series: String, levels: ArrayList<String>) {
        this.tsdb = tsdb
        this.series = series
        this.levels = levels
    }

    public func seriesName(): String { this.series }
    public func levelsOf(): ArrayList<String> { this.levels }

    // ---------- 静态：粒度集 / 校验 / 窗口 ----------

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

    // 校验粒度链：全部在允许集内、严格升序（按窗口毫秒）、无重复、至少 1 档。非法抛异常。
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

    public func count(): Int64 {
        this.tsdb.query(this.series).count()
    }

    // ---------- 分层物化（幂等覆盖，每层落盘不删下层） ----------

    // 物化 now 所在时间窗口的分层桶链（按本 series 的 levels）：
    // 最细层（当前窗口内全部点 → PointRef）→ 逐层向上（当前窗口内已存在的下一层子桶 → BucketRef）。
    // 空窗口不建桶；label 用于桶摘要文案（如「对话」「工具调用」）。
    public func materialize(now: Int64, label: String): Unit {
        let levels = this.levels
        // 最细层：当前 10min 窗口内的所有点 → PointRef
        let fWin = Timeline.windowMs(levels[0])
        let fStart = now - (now % fWin)
        let fKey = this.tsdb.bucketKeyOf(now, fWin)
        let points = this.tsdb.query(this.series).range(fStart, fStart + fWin - 1).find()
        if (points.size > 0) {
            let refs = ArrayList<Ref>()
            for (p in points) { refs.add(Ref.PointRef(this.series, p.ts)) }
            this.tsdb.bucket(this.series, levels[0], fKey,
                levels[0] + " 窗口" + label + " " + points.size.toString() + " 条", refs)
        }
        // 逐层向上：当前窗口内已存在的下一层子桶 → BucketRef
        for (i in 1..levels.size) {
            let level = levels[i]
            let finer = levels[i - 1]
            let win = Timeline.windowMs(level)
            let start = now - (now % win)
            let key = this.tsdb.bucketKeyOf(now, win)
            let refs = ArrayList<Ref>()
            var sub = start
            while (sub < start + win) {
                let subKey = this.tsdb.bucketKeyOf(sub, Timeline.windowMs(finer))
                if (this.tsdb.bucketSummary(this.series, finer, subKey).isSome()) {
                    refs.add(Ref.BucketRef(this.series, finer, subKey))
                }
                sub += Timeline.windowMs(finer)
            }
            if (refs.size > 0) {
                this.tsdb.bucket(this.series, level, key,
                    level + " 窗口覆盖 " + refs.size.toString() + " 个 " + finer + " 子桶", refs)
            }
        }
    }

    // ---------- 精确回想：沿分层桶下钻到原始点 ----------

    public func drillDown(granularity: String, bucketKey: String): ArrayList<Point> {
        let result = ArrayList<Point>()
        this.resolveRefs(this.tsdb.drillDown(this.series, granularity, bucketKey), result)
        result
    }

    private func resolveRefs(refs: ArrayList<Ref>, out: ArrayList<Point>): Unit {
        for (r in refs) {
            match (r) {
                case Ref.PointRef(s, t) =>
                    let pts = this.tsdb.query(s).range(t, t).find()
                    for (p in pts) { out.add(p) }
                case Ref.BucketRef(s, l, k) =>
                    this.resolveRefs(this.tsdb.drillDown(s, l, k), out)
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

    // 窗口桶键（可排序 UTC 键；recall/物化用同一算法）
    public func bucketKeyOf(ts: Int64, windowMs: Int64): String {
        this.tsdb.bucketKeyOf(ts, windowMs)
    }

    // 某粒度下「覆盖 anchor」的物化桶键；anchor 所在桶未物化时回退到最近的更早桶
    public func bucketAt(granularity: String, anchor: Int64): Option<String> {
        let win = Timeline.windowMs(granularity)
        if (win <= 0) { return None }
        let key = this.tsdb.bucketKeyOf(anchor, win)
        if (this.tsdb.bucketSummary(this.series, granularity, key).isSome()) {
            return Some(key)
        }
        let buckets = this.tsdb.listBuckets(this.series, granularity, None, Some(key))
        var latest: Option<String> = None
        for (b in buckets) { latest = Some(b.bucketKey) }
        latest
    }
}

// 分层时间线共享容器：一个 tsdb 实例承载多个 series（<type> 与 <type>.summary）。
// 每 series 带 label（物化桶摘要文案）与 levels（粒度链，§5.1）。
// 注册的 series 由 MaterializeScheduler 统一分层物化（定时推进，不依赖事件发生）。
public class TimelineStore {
    private let tsdb: Tsdb
    private let seriesLabels = HashMap<String, String>()
    private let seriesLevels = HashMap<String, ArrayList<String>>()

    public static func open(path: String): TimelineStore {
        TimelineStore(Tsdb.open(path))
    }

    public static func openInMemory(): TimelineStore {
        TimelineStore(Tsdb.openInMemory())
    }

    private init(tsdb: Tsdb) {
        this.tsdb = tsdb
    }

    public func close(): Unit { this.tsdb.close() }
    public func isClosed(): Bool { this.tsdb.isClosed() }

    // 底层 tsdb（注册表等需要直接读写 __meta / count 用）
    public func rawTsdb(): Tsdb { this.tsdb }

    // 取某 series 的句柄（共享同一 tsdb；句柄不持有所有权，close 走 store）；
    // label 用于物化桶摘要文案；levels 为该 series 的粒度链。
    public func timeline(series: String, label: String, levels: ArrayList<String>): Timeline {
        this.seriesLabels[series] = label
        this.seriesLevels[series] = levels
        Timeline(this.tsdb, series, levels)
    }

    // 全部已注册 series 统一分层物化（MaterializeScheduler 每 60s 调用；幂等、空窗口零成本）
    public func materializeAll(now: Int64): Unit {
        for ((series, label) in this.seriesLabels) {
            Timeline(this.tsdb, series, this.seriesLevels[series]).materialize(now, label)
        }
    }
}

// 定时分层物化（后台线程）：每 60s 一次；幂等、空窗口零成本。
// 只做结构物化（引用链桶），零 LLM 成本；语义摘要不自动物化（见 design.md §7.3）。
public class MaterializeScheduler {
    private let store: TimelineStore

    public init(store: TimelineStore) {
        this.store = store
    }

    // 单次物化（定时循环与测试共用）
    public func materializeNow(): Unit {
        this.store.materializeAll(nowMs())
    }

    // 周期物化循环（后台线程运行）
    public func run(): Unit {
        while (true) {
            sleep(Duration.minute)
            this.materializeNow()
        }
    }
}

// 当前时间戳（毫秒）
public func nowMs(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}
