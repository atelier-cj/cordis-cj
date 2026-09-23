package ystyle::cordis_tests

import ystyle::cordis_core.*
import ystyle::cordis_host.*
import ystyle::jsonrpc.*
import jsonvalue.*
import std.collection.ArrayList
import std.sync.Mutex
import std.fs.{Path, exists}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * xisp 插件端到端测试：真实宿主进程 ↔ 真实 xisp 插件进程（stdio 传输）。
 *
 * 覆盖：
 * - 宿主拉起 ystyle::cordis_xisp.cli + .lisp 脚本 → 握手 → 服务注册 → invoke；
 * - 事件总线：订阅者插件（echo.lisp 订阅 hello）收到发布者插件
 *   （event_emit.lisp）emit 的事件，经宿主扇出路由；
 * - 嵌套 invoke：脚本回调内调用本插件自己的服务（宿主转发回本插件），
 *   验证脚本锁释放窗口无死锁（带超时保护，防测试挂死）；
 * - 热卸载：removePlugin 终止进程并清理服务注册表。
 */
@Test
class XispEndToEndTest {

    // 定位 xisp 插件运行时（相对 workspace 根）
    private static func xispRuntimeBinary(): String {
        "./target/release/bin/ystyle::cordis_xisp.cli"
    }

    private static func entryFor(id: String, script: String, provide: Array<String>): PluginEntry {
        // id / provide / inject 由宿主按 entry 以环境变量下发（CORDIS_PLUGIN_*），
        // 插件侧无需在 args 里重复声明。
        PluginEntry(id, xispRuntimeBinary(),
            args: ArrayList<String>.of(["--script", script]),
            provide: ArrayList<String>.of(provide))
    }

    /** 等待插件服务注册（最多 5 秒）。 */
    private static func waitService(host: PluginHost, service: String): Bool {
        for (_ in 0..100) {
            if (host.state.hasService(service)) {
                return true
            }
            sleep(50 * Duration.millisecond)
        }
        false
    }

    /** 宿主日志中是否出现包含关键字的行。 */
    private static func logContains(logs: ArrayList<String>, lock: Mutex, keyword: String): Bool {
        synchronized(lock) {
            for (line in logs) {
                if (line.contains(keyword)) {
                    return true
                }
            }
        }
        false
    }

    @TestCase
    func testInvokeEchoAndAdd(): Unit {
        let binary = xispRuntimeBinary()
        @Expect(exists(Path(binary)))

        let logs = ArrayList<String>()
        let host = PluginHost(PluginManager(), { _, line => synchronized(Mutex()) { logs.add(line) } })
        let entry = entryFor("lisp-echo", "./cordis_xisp/examples/echo.lisp",
            ["echo", "add", "whoami"])

        let instance = host.launchPlugin(entry)
        @Expect(waitService(host, "echo"))
        @Expect(waitService(host, "add"))

        // whoami → 插件 ID 由宿主按 entry.id 经环境变量下发（cordis.toml 单一来源）
        @Expect(waitService(host, "whoami"))
        let whoResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("whoami", "whoami",
                Array<JsonValue>()))))
        match (whoResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.String(s) => @Expect(s, "lisp-echo")
                    case _ => @Fail("expected plugin id string")
                }
            case Err(e) => @Fail("whoami invoke failed: ${e}")
        }

        // add(7, 8) → 15
        let addResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("add", "add",
                [JsonValue.Number(7.0), JsonValue.Number(8.0)]))))
        match (addResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Number(n) => @Expect(n, 15.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("add invoke failed: ${e}")
        }

        // echo("hi") → "hi"
        let echoResult = instance.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("echo", "echo",
                [JsonValue.String("hi")]))))
        match (echoResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.String(s) => @Expect(s, "hi")
                    case _ => @Fail("expected string result")
                }
            case Err(e) => @Fail("echo invoke failed: ${e}")
        }

        // 热卸载清理
        host.removePlugin("lisp-echo")
        @Expect(!host.state.hasService("echo"))
        @Expect(!host.state.hasService("add"))
    }

    @TestCase
    func testEventRoutingBetweenLispPlugins(): Unit {
        let logs = ArrayList<String>()
        let logLock = Mutex()
        let host = PluginHost(PluginManager(), { _, line =>
            synchronized(logLock) {
                logs.add(line)
            }
        })

        // 1. 先拉起订阅者（echo.lisp 订阅 hello 事件）
        let subEntry = entryFor("lisp-sub", "./cordis_xisp/examples/echo.lisp",
            ["echo", "add"])
        host.launchPlugin(subEntry)
        @Expect(waitService(host, "echo"))
        // 等待订阅注册（宿主日志 "subscribe hello"）
        var subscribed = false
        for (_ in 0..100) {
            synchronized(logLock) {
                for (line in logs) {
                    if (line.contains("subscribe hello")) {
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

        // 2. 拉起发布者（event_emit.lisp 启动时 emit hello）
        let emitEntry = entryFor("lisp-emit", "./cordis_xisp/examples/event_emit.lisp", [])
        host.launchPlugin(emitEntry)

        // 3. 等待订阅者收到并 log（"hello event: world"）
        var received = false
        for (_ in 0..100) {
            synchronized(logLock) {
                for (line in logs) {
                    if (line.contains("hello event: world")) {
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

        // 4. 清理：卸载订阅者后订阅被清理
        host.removePlugin("lisp-sub")
        @Expect(host.eventRegistry.subscriberCount("hello"), 0)
        host.removePlugin("lisp-emit")
    }

    @TestCase
    func testNestedInvokeNoDeadlock(): Unit {
        // 脚本 outer 内 invoke 本插件 inner（宿主转发回本插件）。
        // 若脚本锁未在等待响应前释放 → 死锁；此处用「异步发起 + 限时轮询」保护，
        // 死锁时测试在 5 秒后失败退出而不是卡死整个测试进程。
        let host = PluginHost(PluginManager())
        let entry = entryFor("lisp-nested", "./cordis_xisp/examples/nested_invoke.lisp",
            ["inner", "outer"])
        let instance = host.launchPlugin(entry)
        @Expect(waitService(host, "inner"))
        @Expect(waitService(host, "outer"))

        let resultBox = ArrayList<JsonValue>()
        let resultLock = Mutex()
        spawn {
            let result = instance.client.call<JsonValue, JsonValue>("invoke",
                params: Some(JsonValue.fromObject(InvokeParams("outer", "outer",
                    [JsonValue.Number(21.0)]))))
            let value = match (result) {
                case Ok(v) => v
                case Err(e) => JsonValue.String("ERROR: ${e}")
            }
            synchronized(resultLock) {
                resultBox.add(value)
            }
        }

        // 限时等待结果（5 秒）
        var done = false
        for (_ in 0..100) {
            synchronized(resultLock) {
                if (resultBox.size > 0) {
                    done = true
                }
            }
            if (done) {
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(done)

        let got = synchronized(resultLock) { resultBox[0] }
        match (got) {
            case JsonValue.Number(n) => @Expect(n, 42.0)
            case other => @Fail("expected 42, got ${other}")
        }

        host.removePlugin("lisp-nested")
        @Expect(!host.state.hasService("inner"))
        @Expect(!host.state.hasService("outer"))
    }

    @TestCase
    func testInvalidScriptFailsCleanly(): Unit {
        // 脚本不存在 → 插件进程以非零退出，stderr 经 PluginManager 转发进宿主日志。
        // 注意：插件侧 stderr 由 PluginManager 的 logger 转发（PluginHost 的 logger
        // 只收宿主侧消息），两者需接同一路收集才看得到插件诊断。
        let logs = ArrayList<String>()
        let logLock = Mutex()
        let logger = { _: String, line: String =>
            synchronized(logLock) {
                logs.add(line)
            }
        }
        let host = PluginHost(PluginManager(logger), logger)
        let entry = PluginEntry("lisp-missing", xispRuntimeBinary(),
            args: ArrayList<String>.of(
                ["--script", "./cordis_xisp/examples/does_not_exist.lisp"]))
        host.launchPlugin(entry)

        // 等待宿主记录插件失败（script not found → stderr 转发进宿主日志）
        var failed = false
        for (_ in 0..100) {
            if (logContains(logs, logLock, "script not found")) {
                failed = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        if (!failed) {
            // 失败时打印收到的宿主日志，便于定位（stderr 转发 / 进程状态）
            synchronized(logLock) {
                println("host logs (${logs.size}):")
                for (line in logs) {
                    println("  | ${line}")
                }
            }
        }
        @Expect(failed)
        host.removePlugin("lisp-missing")
    }
}
