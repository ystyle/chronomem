package chronomem.core

import std.collection.*
import std.core.Duration
import std.time.*

// 自然时间窗口（日历对齐，§5.2）测试：day=本地零点 / week=周一起点 / month=1 号零点；
// 分钟/小时保持钟表对齐；桶 key 可排序；日历粒度物化+下钻仍成立。
// 用固定偏移时区（+08:00，无 DST）保证确定性。

func tzPlus8(): TimeZone { TimeZone("UTC+08:00", Duration.hour * 8) }

// 指定时区构造毫秒时间戳
func msOf(tz: TimeZone, y: Int64, mo: Int64, d: Int64, h: Int64, mi: Int64): Int64 {
    DateTime.of(year: y, month: mo, dayOfMonth: d, hour: h, minute: mi, timeZone: tz)
        .toUnixTimeStamp().toMilliseconds()
}

@Test
func timeline_calendarWindow_dayIsLocalMidnight() {
    let store = TimelineStore.openInMemory(timeZone: tzPlus8())
    let tl = store.timeline("cd1", "测试", Timeline.defaultLevels())
    // 2024-01-15 10:30 (+08) → 本地零点 2024-01-15 00:00 (+08)
    let start = tl.windowStartOf(msOf(tzPlus8(), 2024, 1, 15, 10, 30), "day")
    @Expect(start, msOf(tzPlus8(), 2024, 1, 15, 0, 0))
    // 2024-01-15 00:30 (+08) 也归当天
    @Expect(tl.windowStartOf(msOf(tzPlus8(), 2024, 1, 15, 0, 30), "day"), start)
    // 前一天 23:30 → 前一天零点
    @Expect(tl.windowStartOf(msOf(tzPlus8(), 2024, 1, 14, 23, 30), "day"),
        msOf(tzPlus8(), 2024, 1, 14, 0, 0))
    store.close()
}

@Test
func timeline_calendarWindow_weekStartsMonday() {
    let store = TimelineStore.openInMemory(timeZone: tzPlus8())
    let tl = store.timeline("cd2", "测试", Timeline.defaultLevels())
    // 2024-01-15 是周一；2024-01-17（周三）的周起点 = 2024-01-15 00:00
    @Expect(tl.windowStartOf(msOf(tzPlus8(), 2024, 1, 17, 8, 0), "week"),
        msOf(tzPlus8(), 2024, 1, 15, 0, 0))
    // 2024-01-14（周日）属上一周（01-08 周一）
    @Expect(tl.windowStartOf(msOf(tzPlus8(), 2024, 1, 14, 23, 0), "week"),
        msOf(tzPlus8(), 2024, 1, 8, 0, 0))
    store.close()
}

@Test
func timeline_calendarWindow_monthStartsFirst() {
    let store = TimelineStore.openInMemory(timeZone: tzPlus8())
    let tl = store.timeline("cd3", "测试", Timeline.defaultLevels())
    // 2024-01-31 23:00 的月窗口起点 = 2024-01-01 00:00
    @Expect(tl.windowStartOf(msOf(tzPlus8(), 2024, 1, 31, 23, 0), "month"),
        msOf(tzPlus8(), 2024, 1, 1, 0, 0))
    store.close()
}

@Test
func timeline_calendarWindow_fineLevelsClockAligned() {
    let store = TimelineStore.openInMemory(timeZone: tzPlus8())
    let tl = store.timeline("cd4", "测试", Timeline.defaultLevels())
    // 10min 窗口钟表对齐（与 tz 无关）
    let ts = msOf(tzPlus8(), 2024, 1, 15, 10, 30)  // 10:30 → 10:30 所在 10min 段起点 10:30
    @Expect(tl.windowStartOf(ts, "10min") % Int64(600000), Int64(0))
    @Expect(tl.windowStartOf(ts, "1h") % Int64(3600000), Int64(0))
    store.close()
}

@Test
func timeline_calendarWindow_dayDiffersByTimeZone() {
    // 同一绝对时刻：UTC 是 2024-01-14 20:00，+08 是 2024-01-15 04:00 → 各自本地零点不同
    let utcStore = TimelineStore.openInMemory(timeZone: TimeZone.UTC)
    let plus8Store = TimelineStore.openInMemory(timeZone: tzPlus8())
    let utcTl = utcStore.timeline("cd5", "测试", Timeline.defaultLevels())
    let plus8Tl = plus8Store.timeline("cd6", "测试", Timeline.defaultLevels())
    let absolute = msOf(tzPlus8(), 2024, 1, 15, 4, 0)   // = UTC 2024-01-14 20:00
    @Expect(utcTl.windowStartOf(absolute, "day"), msOf(TimeZone.UTC, 2024, 1, 14, 0, 0))
    @Expect(plus8Tl.windowStartOf(absolute, "day"), msOf(tzPlus8(), 2024, 1, 15, 0, 0))
    utcStore.close()
    plus8Store.close()
}

@Test
func timeline_calendarWindow_bucketKeySortable() {
    let store = TimelineStore.openInMemory(timeZone: tzPlus8())
    let tl = store.timeline("cd7", "测试", Timeline.defaultLevels())
    // 桶 key 形如 yyyy-MM-ddTHH:mm:ssZ，字典序 = 时间序
    let k1 = tl.windowKeyOf(msOf(tzPlus8(), 2024, 1, 10, 0, 0), "day")
    let k2 = tl.windowKeyOf(msOf(tzPlus8(), 2024, 1, 15, 0, 0), "day")
    @Expect(k2 > k1, true)
    // day 窗口 key 以本地零点 UTC ISO 表示
    let k3 = tl.windowKeyOf(msOf(tzPlus8(), 2024, 1, 15, 10, 0), "day")
    @Expect(k3, "2024-01-14T16:00:00Z")   // +08 的 1-15 零点 = UTC 1-14 16:00
    store.close()
}

@Test
func timeline_calendarWindow_materializeAndDrillDownDay() {
    let store = TimelineStore.openInMemory(timeZone: tzPlus8())
    let l = ArrayList<String>()
    l.add("day")
    let tl = store.timeline("cd8", "测试", l)
    let start = msOf(tzPlus8(), 2024, 1, 15, 0, 0)
    tl.append(start + 1000, "a", tagsOf([]))
    tl.append(start + 7200000, "b", tagsOf([]))   // 02:00
    tl.materialize(start + 3600000, "测试")
    let key = tl.windowKeyOf(start, "day")
    let points = tl.drillDown("day", key)
    @Expect(points.size, Int64(2))
    store.close()
}

@Test
func timeline_coarsestLevels() {
    let l = Timeline.defaultLevels()   // 10min/30min/1h/day/week
    let top2 = Timeline.coarsestLevels(l, 2)
    @Expect(top2.size, Int64(2))
    @Expect(top2[0], "day")
    @Expect(top2[1], "week")
    let dayWeek = dayWeekLevels()
    let both = Timeline.coarsestLevels(dayWeek, 2)
    @Expect(both.size, Int64(2))
    @Expect(both[0], "day")
    @Expect(both[1], "week")
}
