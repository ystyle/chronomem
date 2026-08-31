package chronomem.core

import std.collection.*
import std.fs.*
import std.sync.*
import std.time.TimeZone
import std.posix.getpid

// 测试共享工具（同包测试文件共用）
// 固定测试基准：2024-01-01 12:00:00 UTC = 1704110400000（10min/30min/1h 窗口起点对齐，便于物化）
public let TEST_BASE = Int64(1704110400000)

// —— 文件型测试库 ——
// 测试必须走真实文件路径（不再 openInMemory：64KB memtable 与生产 16MB memtable 行为不一致，
// 会因 arena 过小而放大"单请求大量条目"的写丢问题）。每进程首次调用清理自己的残留目录
// （测试前清理）；基准目录按 PID 隔离——cjpm test 的多个 TP 并行跑是独立进程，
// 共享固定目录会互相删除对方正在使用的库目录。
let testBaseDir = "/tmp/chronomem-test-" + getpid().toString()
let testInit = AtomicBool(false)
let testSeq = AtomicInt64(0)
let testLock = Mutex()

// 新文件型测试目录（唯一子目录）；进程内首次调用时清掉上次测试残留
public func freshTestDir(): String {
    synchronized(testLock) {
        if (!testInit.load()) {
            if (exists(Path(testBaseDir))) {
                remove(Path(testBaseDir), recursive: true)
            }
            Directory.create(Path(testBaseDir), recursive: true)
            testInit.store(true)
        }
        let dir = testBaseDir + "/t-" + (testSeq.fetchAdd(1)).toString()
        Directory.create(Path(dir), recursive: true)
        return dir
    }
}

// 文件型 TimelineStore（测试用）
// memTableSize 用 4MB（arena 8MB）：测试并发多库，默认 16MB（arena 32MB）会在
// 256MB 默认 GC 堆下 OOM；4MB 对"大桶"压测仍远高于 64KB 病态配置，行为贴近生产。
public func fileStore(timeZone!: TimeZone = TimeZone.Local): TimelineStore {
    TimelineStore.open(freshTestDir(), timeZone: timeZone, memTableSize: 4 * 1024 * 1024u64)
}

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
