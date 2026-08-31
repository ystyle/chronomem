package chronomem.mcp

import chronomem.core.*
import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*
import std.time.*
import std.env.getProcessId
import std.posix.kill

// 优雅退出回归（docker stop / Ctrl+C，badger-cj ≥ 1.6.8）：
// MemoryService.registerSignalShutdown() → SIGTERM 触发后台线程：停 summarize runner →
// tsdb close（flush 落盘）→ 重启数据完整（容器重建/强杀不丢内存数据）。
// 仅 Linux 测试（std.runtime 信号 API 不支持 Windows）。
@When[os == "Linux"]
@Test
class GracefulShutdownTest {

    private static let DIR = "/tmp/chronomem-graceful-shutdown-test-" + getProcessId().toString()

    private func cleanup(): Unit {
        let path = Path(DIR)
        if (exists(path)) {
            remove(path, recursive: true)
        }
    }

    // 向自身进程发 SIGTERM，模拟 docker stop
    private func sendSigterm(): Unit {
        spawn {
            sleep(Duration.millisecond * 200)
            let _ = kill(Int32(getProcessId()), 15)
        }
    }

    // 轮询等待优雅关闭开始（SIGTERM → 后台线程 close → isClosed）
    private func waitClosed(store: TimelineStore): Bool {
        var closed = false
        var attempts = 0
        while (attempts < 200 && !closed) {
            if (store.isClosed()) {
                closed = true
            } else {
                sleep(Duration.millisecond * 50)
                attempts += 1
            }
        }
        closed
    }

    // 等待优雅关闭完全结束：isClosed() 在 close 开始（running=false）即为 true，flush 落盘
    // 在其后执行；固定等待让 close 全流程完成，避免清理/重启与未完成 flush 竞态。
    private func waitFullyClosed(store: TimelineStore): Bool {
        let closed = waitClosed(store)
        sleep(Duration.second * 1)
        closed
    }

    // 建一个带记忆数据的服务（type + 3 条记录）
    private func openServiceWithData(): MemoryService {
        let svc = MemoryService.openFile(DIR)
        let meta = TypeMeta("shut", "graceful shutdown test type", None,
            Timeline.defaultLevels(), None, false, None, 1704110400000)
        svc.registry.create(meta)
        if (let Some(tl) <- svc.registry.timelineOf("shut")) {
            tl.append(1000, "one", HashMap<String, String>())
            tl.append(2000, "two", HashMap<String, String>())
            tl.append(3000, "three", HashMap<String, String>())
        }
        svc
    }

    // 核心：SIGTERM 优雅关闭 → 重启读回全部数据（防复发——不 close 的裸杀会全丢）
    @TestCase
    func testSigtermGracefullyClosesAndPersists(): Unit {
        cleanup()
        let svc = openServiceWithData()
        svc.registerSignalShutdown(exitAfterClose: false)

        sendSigterm()
        @Assert(waitFullyClosed(svc.store), true)

        // 重启同一目录：注册表与 3 条记录须完整恢复
        let svc2 = MemoryService.openFile(DIR)
        try {
            @Assert(svc2.registry.has("shut"), true)
            if (let Some(tl) <- svc2.registry.timelineOf("shut")) {
                let points = tl.queryPoints(0, Int64.Max, 100, None)
                @Assert(points.size == 3)
                // queryPoints 为 reverse（最新在前）
                @Assert(points[0].payload == "three")
                @Assert(points[2].payload == "one")
            } else {
                @Fail("timeline should exist after restart")
            }
        } finally {
            svc2.close()
            cleanup()
        }
    }

    // 幂等：重复注册不崩溃，SIGTERM 一次即触发关闭
    @TestCase
    func testRegisterTwiceIsIdempotent(): Unit {
        cleanup()
        let svc = openServiceWithData()
        svc.registerSignalShutdown(exitAfterClose: false)
        svc.registerSignalShutdown(exitAfterClose: false)

        sendSigterm()
        @Assert(waitFullyClosed(svc.store), true)
        cleanup()
    }
}
