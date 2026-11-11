package ystyle::cordis_tests

import ystyle::cordis_host.*
import ystyle::cordis_core.*
import ystyle::jsonrpc.*
import jsonvalue.*
import std.collection.ArrayList
import std.fs.{Path, exists}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 就绪信号（Methods.READY）：插件 handler 跑完、实现注册完毕之后才通知宿主。
 *
 * 为什么需要它：provide 在插件 handler 之前发出，宿主 awaitActive 通过时
 * registerHandler 可能还没执行，此刻 invoke 会得到「service 未提供」的错误。
 * awaitReady 等到 ready 通知再返回，宿主可以立刻调用。
 */
@Test
class ReadySignalTest {

    private static func pluginBinary(): String {
        "./target/release/bin/ystyle::cordis_plugin.examples.e2e"
    }

    @TestCase
    func testAwaitReadyThenInvokeImmediately(): Unit {
        @Expect(exists(Path(pluginBinary())))
        let manager = PluginManager()
        let host = PluginHost(manager)
        let entry = PluginEntry("ready-plugin", pluginBinary(),
            provide: ArrayList<String>.of(["echo"]))
        let _ = host.launchPlugin(entry)

        // awaitReady = Active（握手 + 服务注册）且收到 ready（实现已注册）
        match (host.awaitReady(entry.id, timeout: 10 * Duration.second)) {
            case Ok(_) => ()
            case Err(msg) => @Fail("awaitReady 失败：" + msg)
        }

        // 就绪之后立刻调用必须成功（这正是修复前的竞态窗口）
        let instance = match (host.state.getInstance(entry.id)) {
            case Some(i) => i
            case None => @Fail("实例不见了")
        }
        let r = instance.client.call<InvokeParams, JsonValue>("invoke",
            params: InvokeParams("echo", "echo", [JsonValue.String("hi")]),
            timeout: 5 * Duration.second)
        match (r) {
            case Ok(v) => match (v) {
                case JsonValue.String(s) => @Expect(s, "hi")
                case _ => @Fail("echo 返回值不是字符串：" + v.toString())
            }
            case Err(e) => @Fail("invoke 失败：" + e)
        }
        host.removePlugin(entry.id)
    }

    @TestCase
    func testReadyFlagIsSetAfterProvide(): Unit {
        @Expect(exists(Path(pluginBinary())))
        let manager = PluginManager({ id: String, line: String => eprintln("[plugin:" + id + "] " + line) })
        let host = PluginHost(manager)
        let entry = PluginEntry("ready-flag", pluginBinary(),
            provide: ArrayList<String>.of(["echo"]))
        let _ = host.launchPlugin(entry)
        match (host.awaitReady(entry.id, timeout: 10 * Duration.second)) {
            case Ok(inst) =>
                let ready = synchronized(inst.settleLock) {
                    inst.ready
                }
                @Expect(ready)
            case Err(msg) => @Fail("awaitReady 失败：" + msg)
        }
        host.removePlugin(entry.id)
    }
}
