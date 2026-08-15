package ystyle::cordis_tests

import ystyle::cordis_host.*
import ystyle::cordis_core.*
import ystyle::jsonrpc.*
import jsonvalue.*
import std.collection.{HashMap, ArrayList}
import std.sync.Mutex
import std.fs.{Path, exists, File, OpenMode, remove}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 端到端测试：真实宿主（PluginHost + PluginManager + PipeTransport）
 * 拉起真实插件进程（ystyle::cordis_plugin.examples.e2e），验证
 * 握手/服务注册/invoke 转发/热卸载/崩溃自愈全流程。
 *
 * 插件可执行文件通过 workspace build 产出：
 *   target/release/bin/ystyle::cordis_plugin.examples.e2e
 */
@Test
class EndToEndTest {

    // 定位插件可执行文件（相对 workspace 根）
    private static func pluginBinary(): String {
        "./target/release/bin/ystyle::cordis_plugin.examples.e2e"
    }

    private static func makeEntry(): PluginEntry {
        PluginEntry("e2e-plugin", pluginBinary(),
            provide: ArrayList<String>.of(["echo", "add"]))
    }

    @TestCase
    func testFullLifecycle(): Unit {
        // 前置：插件二进制存在
        @Expect(exists(Path(pluginBinary())))
        let manager = PluginManager()
        let host = PluginHost(manager)
        let entry = makeEntry()

        // 1. 拉起插件（启动握手在后台完成）
        let instance = host.launchPlugin(entry)

        // 2. 等待插件 Active（initialize 握手完成）+ 服务注册完成
        var active = false
        for (i in 0..200) {
            if (instance.status == InstanceStatus.Active) {
                active = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(active)
        @Expect(host.state.hasService("echo"))
        @Expect(host.state.hasService("add"))

        // 3. invoke 转发：宿主 → 插件服务调用
        // 宿主侧用 instance.client 向插件发 invoke 请求
        let invokeResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("add", "add",
                [JsonValue.Number(2.0), JsonValue.Number(3.0)]))))
        match (invokeResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Number(n) => @Expect(n, 5.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("invoke failed: ${e}")
        }

        // echo 服务
        let echoResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("echo", "echo",
                [JsonValue.String("hello-cordis")]))))
        match (echoResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.String(s) => @Expect(s, "hello-cordis")
                    case _ => @Fail("expected string result")
                }
            case Err(e) => @Fail("echo failed: ${e}")
        }

        // 4. 热卸载：终止插件，服务注册表清理
        host.removePlugin("e2e-plugin")
        @Expect(!host.state.hasService("echo"))
        @Expect(!host.state.hasService("add"))
        @Expect(host.state.actual.size, 0)
    }

    @TestCase
    func testReconcileFromConfig(): Unit {
        // 写一个临时 TOML 配置，验证 Reconciler 从配置拉起插件
        let configPath = "./.e2e_config.toml"
        let toml = """
            interval = 5
            ping_interval = 30

            [[plugins]]
            id = "e2e-plugin"
            source = "${pluginBinary()}"
            provide = ["echo", "add"]
        """
        let file = File(configPath, OpenMode.Write)
        file.write(toml.toArray())
        file.flush()

        let manager = PluginManager()
        let host = PluginHost(manager)
        host.reconcile(configPath)

        // 等待插件 Active + 服务注册
        var ready = false
        for (i in 0..200) {
            if (host.state.hasService("echo") && host.state.hasService("add")) {
                ready = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(ready)

        // 清理
        host.removePlugin("e2e-plugin")
        remove(Path(configPath))
    }

    @TestCase
    func testCrashRestart(): Unit {
        // 崩溃自愈：插件进程被杀后，下一次调谐自动重启
        let manager = PluginManager()
        let host = PluginHost(manager)
        let entry = makeEntry()
        let instance = host.launchPlugin(entry)

        // 等 Active
        var active = false
        for (i in 0..200) {
            if (instance.status == InstanceStatus.Active) {
                active = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(active)

        // 强制杀死进程（模拟崩溃）
        instance.process.terminate(force: true)
        instance.process.wait()

        // 下一次调谐应检测到崩溃并重启（desired 仍存在）
        // 手动构造 desired 状态并触发 healCrashed
        // 注：reconcileDesired 需要 desired 有该条目；通过 addDesired 模拟
        host.state.addDesired(entry)
        // 等待 client 检测到 EOF（isExited）
        var exited = false
        for (i in 0..100) {
            if (manager.isExited(instance)) {
                exited = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(exited)
        // 触发调谐
        host.reconcileDesired()
        // 等待新实例出现且 Active
        var restarted = false
        for (i in 0..200) {
            let inst = host.state.getInstance("e2e-plugin")
            match (inst) {
                case Some(i2) =>
                    if (i2.status == InstanceStatus.Active) {
                        restarted = true
                        break
                    }
                case None => ()
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(restarted)
        // 清理
        host.removePlugin("e2e-plugin")
    }

    @TestCase
    func testMacroPluginLifecycle(): Unit {
        // 宏插件（@Plugin + @Provide 生成）端到端：握手/服务注册/invoke
        let macroBinary = "./target/release/bin/ystyle::cordis_plugin.examples.macro_demo"
        @Expect(exists(Path(macroBinary)))
        let manager = PluginManager()
        let host = PluginHost(manager)
        let entry = PluginEntry("macro-plugin", macroBinary,
            provide: ArrayList<String>.of(["echo", "add"]))

        let instance = host.launchPlugin(entry)
        // 等待 Active + 服务注册
        var ready = false
        for (i in 0..200) {
            if (host.state.hasService("echo") && host.state.hasService("add")) {
                ready = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(ready)

        // invoke add(2,3) → 5（宏生成的方法路由）
        let addResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("add", "add",
                [JsonValue.Number(2.0), JsonValue.Number(3.0)]))))
        match (addResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Number(n) => @Expect(n, 5.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("macro invoke failed: ${e}")
        }

        // invoke echo("hello-macro") → "hello-macro"
        let echoResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("echo", "echo",
                [JsonValue.String("hello-macro")]))))
        match (echoResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.String(s) => @Expect(s, "hello-macro")
                    case _ => @Fail("expected string result")
                }
            case Err(e) => @Fail("macro echo failed: ${e}")
        }

        // 热卸载清理
        host.removePlugin("macro-plugin")
        @Expect(!host.state.hasService("echo"))
        @Expect(!host.state.hasService("add"))
    }

    @TestCase
    func testExternalPluginLifecycle(): Unit {
        // 独立模块插件（不依赖宏，PluginRuntime.run 显式 API）：
        // 验证外部插件作者在「cjpm 带 org 宏包跨模块缺陷」下仍可开发插件
        let externalBinary = "./target/release/bin/ystyle::cordis_examples"
        @Expect(exists(Path(externalBinary)))
        let manager = PluginManager()
        let host = PluginHost(manager)
        let entry = PluginEntry("external-plugin", externalBinary,
            provide: ArrayList<String>.of(["echo", "add"]))

        let instance = host.launchPlugin(entry)
        // 等待 Active + 服务注册
        var ready = false
        for (i in 0..200) {
            if (host.state.hasService("echo") && host.state.hasService("add")) {
                ready = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(ready)

        // invoke add(7,8) → 15
        let addResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("add", "add",
                [JsonValue.Number(7.0), JsonValue.Number(8.0)]))))
        match (addResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Number(n) => @Expect(n, 15.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("external invoke failed: ${e}")
        }

        // 热卸载清理
        host.removePlugin("external-plugin")
        @Expect(!host.state.hasService("echo"))
        @Expect(!host.state.hasService("add"))
    }

    @TestCase
    func testEventBusEndToEnd(): Unit {
        // 事件总线端到端：真实宿主 + 真实双插件进程
        // 订阅者（event-sub）先启动并订阅 stats/report；
        // 发布者（event-emit）后启动，emit 经宿主路由到订阅者，
        // 订阅者收到后 log 通知宿主（通过 logger 回调收集验证）
        let subBinary = "./target/release/bin/ystyle::cordis_plugin.examples.event_sub"
        let emitBinary = "./target/release/bin/ystyle::cordis_plugin.examples.event_emit"
        @Expect(exists(Path(subBinary)))
        @Expect(exists(Path(emitBinary)))

        // 收集宿主日志（验证订阅者收到事件后 log）
        let logs = ArrayList<String>()
        let logLock = Mutex()
        let host = PluginHost(PluginManager(), { _, line =>
            synchronized(logLock) {
                logs.add(line)
            }
        })

        // 1. 先拉起订阅者（保证订阅先注册）
        let subEntry = PluginEntry("event-sub", subBinary)
        host.launchPlugin(subEntry)
        // 等待订阅者注册订阅（通过宿主日志 "subscribe stats/report" 验证）
        var subscribed = false
        for (i in 0..100) {
            synchronized(logLock) {
                for (line in logs) {
                    if (line.contains("subscribe stats/report")) {
                        subscribed = true
                        break
                    }
                }
            }
            if (subscribed) {
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(subscribed)

        // 2. 拉起发布者（启动后 emit 两个事件）
        let emitEntry = PluginEntry("event-emit", emitBinary)
        host.launchPlugin(emitEntry)

        // 3. 等待订阅者收到事件并 log（"received stats/report count=..."）
        var received = false
        for (i in 0..100) {
            synchronized(logLock) {
                for (line in logs) {
                    if (line.contains("received stats/report count=1.0") ||
                        line.contains("received stats/report count=1")) {
                        received = true
                        break
                    }
                }
            }
            if (received) {
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(received)

        // 4. 清理：卸载订阅者，验证订阅被清理
        host.removePlugin("event-sub")
        @Expect(host.eventRegistry.subscriberCount("stats/report"), 0)
        host.removePlugin("event-emit")
    }
}
