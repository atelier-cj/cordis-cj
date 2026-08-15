package ystyle::cordis_tests

import ystyle::cordis_host.*
import ystyle::cordis_core.*
import ystyle::jsonrpc.*
import jsonvalue.*
import std.collection.ArrayList
import std.process.{launch, ProcessRedirect}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * EventRegistry 测试（docs/design-events.md §5）
 * 覆盖：订阅/退订/按插件清理/subscriberCount
 *
 * 说明：dispatch 真实派发（走 client.call 到 events/dispatch）在
 * P6.3/P6.4 用 FakeHost/真实插件验证；此处验证注册表纯逻辑。
 */
@Test
class EventRegistryTest {

    // 构造一个测试用 PluginInstance（真实子进程 + 管道 client，不启动）
    private static func makeInstance(pluginId: String): PluginInstance {
        let entry = PluginEntry(pluginId, "/bin/true")
        let proc = launch("/bin/true", [],
            stdIn: ProcessRedirect.Pipe,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe)
        let transport = PipeTransport(proc)
        let client = JsonRpcClient(transport)
        PluginInstance(entry, proc, client)
    }

    @TestCase
    func testSubscribeAndUnsubscribe(): Unit {
        let registry = EventRegistry()
        let inst = makeInstance("plugin-a")
        let id = registry.subscribe("stats/report", "plugin-a", inst)
        @Expect(registry.subscriberCount("stats/report"), 1)
        // 退订
        let removed = registry.unsubscribe(id)
        @Expect(removed)
        @Expect(registry.subscriberCount("stats/report"), 0)
        // 重复退订返回 false
        @Expect(!registry.unsubscribe(id))
        // 清理子进程
        inst.process.terminate(force: true)
        inst.process.wait()
    }

    @TestCase
    func testMultipleSubscribers(): Unit {
        let registry = EventRegistry()
        let instA = makeInstance("plugin-a")
        let instB = makeInstance("plugin-b")
        registry.subscribe("stats/report", "plugin-a", instA)
        registry.subscribe("stats/report", "plugin-b", instB)
        registry.subscribe("other/event", "plugin-a", instA)
        @Expect(registry.subscriberCount("stats/report"), 2)
        @Expect(registry.subscriberCount("other/event"), 1)
        // 清理
        instA.process.terminate(force: true)
        instA.process.wait()
        instB.process.terminate(force: true)
        instB.process.wait()
    }

    @TestCase
    func testUnsubscribeAllByPlugin(): Unit {
        let registry = EventRegistry()
        let instA = makeInstance("plugin-a")
        let instB = makeInstance("plugin-b")
        registry.subscribe("e1", "plugin-a", instA)
        registry.subscribe("e2", "plugin-a", instA)
        registry.subscribe("e1", "plugin-b", instB)
        // 插件 A 卸载：清理其全部订阅
        registry.unsubscribeAll("plugin-a")
        @Expect(registry.subscriberCount("e1"), 1)   // 只剩 B
        @Expect(registry.subscriberCount("e2"), 0)   // A 的 e2 被清
        // B 的订阅保留
        let removed = registry.unsubscribe("sub-3")
        @Expect(removed)
        @Expect(registry.subscriberCount("e1"), 0)
        // 清理
        instA.process.terminate(force: true)
        instA.process.wait()
        instB.process.terminate(force: true)
        instB.process.wait()
    }

    @TestCase
    func testSubscribeIdSequence(): Unit {
        let registry = EventRegistry()
        let inst = makeInstance("plugin-a")
        let id1 = registry.subscribe("e1", "plugin-a", inst)
        let id2 = registry.subscribe("e1", "plugin-a", inst)
        @Expect(id1, "sub-1")
        @Expect(id2, "sub-2")
        @Expect(registry.subscriberCount("e1"), 2)   // 同插件同事件允许重复订阅
        // 清理
        inst.process.terminate(force: true)
        inst.process.wait()
    }
}
