package ystyle::cordis_tests

import ystyle::cordis_host.*
import ystyle::cordis_core.*
import jsonvalue.*
import std.collection.ArrayList
import std.sync.Mutex
import std.fs.{Path, exists}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * `PluginHost.setEmitTrace`：事件追踪默认关、可开。
 *
 * 为什么需要这个开关：cordis 的事件通道可以被当数据面用（harness 的文本增量一秒几十条），
 * 逐条打「emit x -> N subscribers」会把真正有用的日志淹掉，而且它走的是宿主 logger，
 * 与插件日志混在一起。默认安静；排查订阅关系时显式打开。
 *
 * 覆盖：
 * 1. 默认关：插件 emit / parallel 都不产生宿主日志；
 * 2. 打开后：两条路径（通知 / 请求）各产生一行；
 * 3. 再关掉：日志重新消失（开关是活的，不是构造期一次性）。
 */
@Test
class EmitTraceTest {

    private static let emitBinary: String = "./target/release/bin/ystyle::cordis_plugin.examples.event_emit"
    private static let burstBinary: String = "./target/release/bin/ystyle::cordis_plugin.examples.burst_emit"

    // 收集宿主日志
    private static func collect(): (ArrayList<String>, Mutex) {
        return (ArrayList<String>(), Mutex())
    }

    private static func hasLine(lines: ArrayList<String>, lock: Mutex, needle: String): Bool {
        synchronized(lock) {
            for (l in lines) {
                if (l.contains(needle)) {
                    return true
                }
            }
            return false
        }
    }

    private static func waitFor(lines: ArrayList<String>, lock: Mutex, needle: String, timeoutMs: Int64): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMs) {
            if (hasLine(lines, lock, needle)) {
                return true
            }
            sleep(20 * Duration.millisecond)
            waited = waited + 20
        }
        return hasLine(lines, lock, needle)
    }

    private static func countLines(lines: ArrayList<String>, lock: Mutex, needle: String): Int64 {
        synchronized(lock) {
            var n: Int64 = 0
            for (l in lines) {
                if (l.contains(needle)) {
                    n = n + 1
                }
            }
            return n
        }
    }

    @TestCase
    func testEmitTraceIsOffByDefaultAndCanBeTurnedOn(): Unit {
        @Expect(exists(Path(emitBinary)))
        // ── 默认关 ──
        let (lines1, lock1) = collect()
        let host1 = PluginHost(PluginManager(), { id, line => synchronized(lock1) { lines1.add(line) } })
        @Expect(!host1.isEmitTraceEnabled())
        host1.launchPlugin(PluginEntry("event-emit", emitBinary))
        // 插件在 emit 之后才 log：「published 2 events」到达即说明两次 emit 已派发
        @Expect(waitFor(lines1, lock1, "event-emit published 2 events", 10000))
        @Expect(countLines(lines1, lock1, "emit stats/report"), 0)
        host1.removePlugin("event-emit")

        // ── 打开 ──
        let (lines2, lock2) = collect()
        let host2 = PluginHost(PluginManager(), { id, line => synchronized(lock2) { lines2.add(line) } })
        host2.setEmitTrace(true)
        @Expect(host2.isEmitTraceEnabled())
        host2.launchPlugin(PluginEntry("event-emit", emitBinary))
        @Expect(waitFor(lines2, lock2, "emit stats/report", 10000))
        @Expect(countLines(lines2, lock2, "emit stats/report ->"), 2)
        host2.removePlugin("event-emit")
    }

    @TestCase
    func testEmitTraceCoversTheRequestDispatchPath(): Unit {
        @Expect(exists(Path(burstBinary)))
        // 默认关：serial（请求式派发）同样不打印
        let (lines1, lock1) = collect()
        let host1 = PluginHost(PluginManager(), { id, line => synchronized(lock1) { lines1.add(line) } })
        let inst1 = host1.launchPlugin(PluginEntry("burst-emit", burstBinary,
            provide: ArrayList<String>.of(["burst"])))
        @Expect(waitForActive(host1, inst1))
        invokeSerial(inst1)
        @Expect(countLines(lines1, lock1, "burst/ser"), 0)

        // 打开：出现 mode=serial 那一行
        let (lines2, lock2) = collect()
        let host2 = PluginHost(PluginManager(), { id, line => synchronized(lock2) { lines2.add(line) } })
        host2.setEmitTrace(true)
        let inst2 = host2.launchPlugin(PluginEntry("burst-emit", burstBinary,
            provide: ArrayList<String>.of(["burst"])))
        @Expect(waitForActive(host2, inst2))
        invokeSerial(inst2)
        @Expect(waitFor(lines2, lock2, "emit burst/ser mode=", 5000))

        // 关掉后不再增长
        host2.setEmitTrace(false)
        let before = countLines(lines2, lock2, "emit burst/ser")
        invokeSerial(inst2)
        sleep(300 * Duration.millisecond)
        @Expect(countLines(lines2, lock2, "emit burst/ser"), before)

        host1.removePlugin("burst-emit")
        host2.removePlugin("burst-emit")
    }

    private static func waitForActive(host: PluginHost, instance: PluginInstance): Bool {
        for (i in 0..200) {
            if (instance.status == InstanceStatus.Active && host.state.hasService("burst")) {
                return true
            }
            sleep(50 * Duration.millisecond)
        }
        return false
    }

    private static func invokeSerial(instance: PluginInstance): Unit {
        let r = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("burst", "ser", []))))
        match (r) {
            case Ok(_) => ()
            case Err(e) => @Fail("invoke ser 失败：" + e)
        }
    }
}
