package chronomem.core

import std.collection.*

// 测试共享工具（同包测试文件共用）
// 固定测试基准：2024-01-01 12:00:00 UTC = 1704110400000（10min/30min/1h 窗口起点对齐，便于物化）
public let TEST_BASE = Int64(1704110400000)

public func inMemStore(): TimelineStore { TimelineStore.openInMemory() }

public func tagsOf(kv: Array<(String, String)>): HashMap<String, String> {
    let m = HashMap<String, String>()
    for ((k, v) in kv) { m[k] = v }
    m
}

public func dayWeekLevels(): ArrayList<String> {
    let l = ArrayList<String>()
    l.add("day")
    l.add("week")
    l
}

public func testMeta(name: String, levels: ArrayList<String>): TypeMeta {
    TypeMeta(name, "desc " + name, Some("{\"a\":\"string\"}"), levels, None,
        false, None, TEST_BASE)
}
