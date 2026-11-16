package ystyle::cordis_tests

import ystyle::cordis_host.*
import ystyle::cordis_core.*
import jsonvalue.*
import std.collection.ArrayList
import std.sync.{Mutex, Condition}
import std.fs.{Path, exists}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 插件 → 宿主：**连续高频 emit** 的可靠性。
 *
 * 为什么单独测它：harness 的事件流形态就是「一个回合里成百上千条增量」，
 * 插件必须能在处理线程上连续上报而不打断连接、不丢事件、不乱序。
 * 早期实测该路径首帧后断连，数据面因此退到 stderr；本用例把那条路径钉住：
 * 只要这里红，就说明「改用协议通道」这条路走不通，别再往回搬。
 *
 * 覆盖：
 * 1. 单线程连续 emit 200 条 → 全部到达且保序；
 * 2. 事件流结束后连接仍可用（再发一轮 300 条），不是「最后一帧即断」；
 * 3. 两个处理线程并发 emit 到不同事件名 → 两条流各自完整，帧不互相截断。
 */
// 事件计数器：宿主本地订阅收到的序号
class BurstCounter {
    public let values: ArrayList<Int64> = ArrayList<Int64>()
    public let lock: Mutex = Mutex()
    public let cond: Condition

    init() {
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    public func add(v: Int64): Unit {
        synchronized(this.lock) {
            this.values.add(v)
            this.cond.notifyAll()
        }
    }

    public func waitAtLeast(n: Int64, timeoutMs: Int64): Bool {
        synchronized(this.lock) {
            var waited: Int64 = 0
            while (this.values.size < n && waited < timeoutMs) {
                this.cond.wait(timeout: 20 * Duration.millisecond)
                waited = waited + 20
            }
            return this.values.size >= n
        }
    }

    public func size(): Int64 {
        synchronized(this.lock) {
            return this.values.size
        }
    }

    // 事件流必须保序：序号从 0 递增
    public func ordered(): Bool {
        synchronized(this.lock) {
            for (i in 0..this.values.size) {
                if (this.values[i] != i) {
                    return false
                }
            }
            return true
        }
    }
}

@Test
class EmitBurstTest {

    private static let binary: String = "./target/release/bin/ystyle::cordis_plugin.examples.burst_emit"

    private static func numOf(args: Array<JsonValue>): Int64 {
        if (args.size == 0) {
            return Int64(-1)
        }
        return match (args[0]) {
            case JsonValue.Number(x) => Int64(x)
            case _ => Int64(-1)
        }
    }

    private static func launch(): (PluginHost, PluginInstance) {
        @Expect(exists(Path(binary)))
        let host = PluginHost(PluginManager())
        let entry = PluginEntry("burst-emit", binary,
            provide: ArrayList<String>.of(["burst"]))
        let instance = host.launchPlugin(entry)
        var active = false
        for (i in 0..200) {
            if (instance.status == InstanceStatus.Active && host.state.hasService("burst")) {
                active = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(active)
        return (host, instance)
    }

    private static func invokeBurst(instance: PluginInstance, n: Int64, event: String): Unit {
        let result = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("burst", "go",
                [JsonValue.Number(Float64(n)), JsonValue.String(event)]))))
        match (result) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Number(x) => @Expect(Int64(x), n)
                    case other => @Fail("burst 返回了非数字：" + other.toString())
                }
            case Err(e) => @Fail("invoke burst 失败：" + e)
        }
    }

    @TestCase
    func testBurstEmitIsReliableAndKeepsConnection(): Unit {
        let (host, instance) = launch()
        let counter = BurstCounter()
        let sub = host.eventRegistry.subscribeLocal("burst/tick", { args => counter.add(numOf(args)) })

        // 1. 一轮 200 条
        invokeBurst(instance, 200, "burst/tick")
        @Expect(counter.waitAtLeast(200, 15000))
        @Expect(counter.size(), 200)
        @Expect(counter.ordered())

        // 2. 连接仍在：换一个订阅再发 300 条
        let second = BurstCounter()
        host.eventRegistry.unsubscribeLocal(sub)
        let sub2 = host.eventRegistry.subscribeLocal("burst/tick", { args => second.add(numOf(args)) })
        invokeBurst(instance, 300, "burst/tick")
        @Expect(second.waitAtLeast(300, 20000))
        @Expect(second.size(), 300)
        @Expect(second.ordered())
        @Expect(instance.status, InstanceStatus.Active)
        host.eventRegistry.unsubscribeLocal(sub2)

        host.removePlugin("burst-emit")
    }

    @TestCase
    func testConcurrentBurstsDoNotInterleave(): Unit {
        let (host, instance) = launch()
        let a = BurstCounter()
        let b = BurstCounter()
        host.eventRegistry.subscribeLocal("burst/one", { args => a.add(numOf(args)) })
        host.eventRegistry.subscribeLocal("burst/two", { args => b.add(numOf(args)) })

        let t1 = spawn { invokeBurst(instance, 300, "burst/one") }
        let t2 = spawn { invokeBurst(instance, 300, "burst/two") }
        t1.get()
        t2.get()

        @Expect(a.waitAtLeast(300, 20000))
        @Expect(b.waitAtLeast(300, 20000))
        @Expect(a.size(), 300)
        @Expect(b.size(), 300)
        @Expect(instance.status, InstanceStatus.Active)

        host.removePlugin("burst-emit")
    }
}
