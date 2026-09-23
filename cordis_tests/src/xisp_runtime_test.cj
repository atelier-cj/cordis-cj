package ystyle::cordis_tests

import ystyle::cordis_core.*
import ystyle::cordis_plugin.*
import ystyle::cordis_xisp.XispPluginRuntime
import ystyle::jsonrpc.*
import jsonvalue.*
import std.collection.{HashMap, ArrayList}
import std.sync.{Mutex, Condition}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * xisp 插件运行时测试（内存双端）：
 *
 * 用 MemoryDuplexTransport 将宿主侧 JsonRpcClient 与插件侧
 * PluginRuntime + XispPluginRuntime 直接对接，验证脚本注册的
 * handler / 定时器 / 配置读取 / 错误传播，无需真实子进程。
 *
 * 事件路由与嵌套 invoke（脚本锁释放窗口）在 xisp_e2e_test.cj
 * 用真实宿主覆盖（那里有真实 serviceIndex 转发与扇出）。
 */

/**
 * 模拟宿主：初始化握手 + provide 分配 undo_id + log 收集 + 配置下发。
 */
private class XispFakeHost {
    let client: JsonRpcClient
    let lock: Mutex = Mutex()
    let cond: Condition
    var initialized: Bool = false
    var provided: ArrayList<String> = ArrayList()
    var logs: ArrayList<String> = ArrayList()
    var handlerRan: Bool = false
    var initFailed: Bool = false
    // 下发给插件的私有配置（initialize 响应）
    let config: JsonValue

    init(client: JsonRpcClient, config: JsonValue) {
        this.client = client
        this.config = config
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    func markHandlerRan(): Unit {
        synchronized(this.lock) {
            this.handlerRan = true
            this.cond.notifyAll()
        }
    }

    func markInitFailed(): Unit {
        synchronized(this.lock) {
            this.initFailed = true
            this.cond.notifyAll()
        }
    }

    func waitFor(predicate: () -> Bool): Bool {
        synchronized(this.lock) {
            var waited = 0
            while (!predicate() && waited < 200) {
                this.cond.wait(timeout: 50 * Duration.millisecond)
                waited++
            }
            predicate()
        }
    }
}

@Test
class XispRuntimeTest {

    /**
     * 内存双端装配：宿主 client + 插件 runtime（独立线程）。
     * 插件完成握手后执行脚本，脚本注册 handler 到协议。
     */
    private static func setupXisp(script: String, config!: JsonValue = JsonValue.Null):
        (XispFakeHost, MemoryDuplexTransport, MemoryDuplexTransport) {
        let (hostT, pluginT) = MemoryDuplexTransport.pair()
        let client = JsonRpcClient(hostT, framing: NewlineFraming())
        let host = XispFakeHost(client, config)

        // 宿主处理 initialize：返回 ok + providers + config
        client.registerRequestHandler(Methods.INITIALIZE, { _ =>
            let providers = HashMap<String, String>()
            let result = InitializeResult(true, providers, config: Some(host.config))
            Some(JsonValue.fromObject(result))
        })
        // 宿主处理 provide：分配 undo_id
        client.registerRequestHandler(Methods.PROVIDE, { req =>
            match (req.params) {
                case Some(p) =>
                    match (p["key"]) {
                        case Some(JsonValue.String(k)) =>
                            synchronized(host.lock) {
                                host.provided.add(k)
                                host.cond.notifyAll()
                            }
                        case _ => ()
                    }
                case None => ()
            }
            synchronized(host.lock) {
                Some(JsonValue.fromObject(ProvideResult("undo-${host.provided.size}")))
            }
        })
        // 宿主处理 log：记录日志
        client.setNotificationCallback({ notif =>
            if (notif.method == Methods.LOG) {
                match (notif.params) {
                    case Some(p) =>
                        match (p["message"]) {
                            case Some(JsonValue.String(m)) =>
                                synchronized(host.lock) {
                                    host.logs.add(m)
                                    host.cond.notifyAll()
                                }
                            case _ => ()
                        }
                    case None => ()
                }
            }
        })
        client.start()

        spawn {
            PluginRuntime.run(pluginT, "xisp-plugin", [], [], { ctx =>
                // 脚本初始化（注册 handler/监听器/定时器）完成后再标记就绪，
                // 否则测试线程可能在脚本尚未注册 handler 时就发 invoke（竞态）。
                // 初始化失败（语法/运行错误）标记失败标志，供失败路径测试等待。
                try {
                    let _ = XispPluginRuntime.attachText(ctx, "xisp-plugin", script)
                    host.markHandlerRan()
                } catch (e: Exception) {
                    host.markInitFailed()
                }
            })
        }
        (host, hostT, pluginT)
    }

    /** 宿主侧发起 invoke 并断言数字结果。 */
    private static func invokeNumber(host: XispFakeHost, service: String, method: String,
                                     args: Array<JsonValue>): Float64 {
        let result = host.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams(service, method, args))))
        match (result) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Number(n) => n
                    case other => throw Exception("expected number, got ${other}")
                }
            case Err(e) => throw Exception("invoke failed: ${e}")
        }
    }

    /** 宿主侧发起 invoke 并返回原始 JsonValue。 */
    private static func invokeRaw(host: XispFakeHost, service: String, method: String,
                                  args: Array<JsonValue>): JsonValue {
        let result = host.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams(service, method, args))))
        match (result) {
            case Ok(v) => v
            case Err(e) => throw Exception("invoke failed: ${e}")
        }
    }

    @TestCase
    func testEchoAndAddInvoke(): Unit {
        let script = """
        (cordis::log "info" "ready")
        (cordis::register-handler "echo" (lambda (method args)
          (if (> (length args) 0) (car args) nil)))
        (cordis::register-handler "add" (lambda (method args)
          (+ (car args) (car (cdr args)))))
        """
        let (host, hostT, pluginT) = setupXisp(script)
        // 等待插件 handler 执行（握手 + 脚本初始化完成）
        @Expect(host.waitFor({ => host.handlerRan }))

        // echo("hi") → "hi"
        let echoed = invokeRaw(host, "echo", "echo", [JsonValue.String("hi")])
        match (echoed) {
            case JsonValue.String(s) => @Expect(s, "hi")
            case other => @Fail("expected string, got ${other}")
        }

        // add(7, 8) → 15
        let sum = invokeNumber(host, "add", "add", [JsonValue.Number(7.0), JsonValue.Number(8.0)])
        @Expect(sum, 15.0)

        // 无参数 echo → nil → null
        let empty = invokeRaw(host, "echo", "echo", Array<JsonValue>())
        match (empty) {
            case JsonValue.Null => ()
            case other => @Fail("expected null, got ${other}")
        }

        hostT.close()
        pluginT.close()
    }

    @TestCase
    func testHandlerErrorSurfacesAsInvokeError(): Unit {
        // handler 内调用未定义函数 → 错误值 → INVOKE-ERROR 文本
        let script = """
        (cordis::register-handler "boom" (lambda (method args)
          (undefined-function-xyz 1)))
        """
        let (host, hostT, pluginT) = setupXisp(script)
        @Expect(host.waitFor({ => host.handlerRan }))

        let result = host.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("boom", "boom", Array<JsonValue>()))))
        match (result) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.String(s) => @Assert(s.contains("INVOKE-ERROR"))
                    case other => @Fail("expected error string, got ${other}")
                }
            case Err(e) => @Fail("invoke should succeed at protocol level: ${e}")
        }
        hostT.close()
        pluginT.close()
    }

    @TestCase
    func testProvideReturnsUndoId(): Unit {
        let script = """
        (cordis::provide "extra")
        """
        let (host, hostT, pluginT) = setupXisp(script)
        @Expect(host.waitFor({ => host.handlerRan }))
        // 脚本顶层 provide → 宿主收到 provide 请求
        @Expect(host.waitFor({ => host.provided.size > 0 }))
        @Expect(host.provided[0], "extra")
        hostT.close()
        pluginT.close()
    }

    @TestCase
    func testConfigExposedToScript(): Unit {
        // 宿主下发配置 {port: 8080, name: "demo"}
        let cfgMap = HashMap<String, JsonValue>()
        cfgMap.add("port", JsonValue.Number(8080.0))
        cfgMap.add("name", JsonValue.String("demo"))
        let cfg = JsonValue.fromObject(cfgMap)
        let script = """
        (cordis::register-handler "cfg" (lambda (method args)
          (cordis::config)))
        """
        let (host, hostT, pluginT) = setupXisp(script, config: cfg)
        @Expect(host.waitFor({ => host.handlerRan }))

        // handler 返回 (cordis::config) → 宿主侧拿到下发配置
        let got = invokeRaw(host, "cfg", "cfg", Array<JsonValue>())
        match (got) {
            case JsonValue.Map(m) =>
                match (m.get("port")) {
                    case Some(JsonValue.Number(n)) => @Expect(n, 8080.0)
                    case _ => @Fail("config.port missing")
                }
                match (m.get("name")) {
                    case Some(JsonValue.String(s)) => @Expect(s, "demo")
                    case _ => @Fail("config.name missing")
                }
            case other => @Fail("expected map, got ${other}")
        }
        hostT.close()
        pluginT.close()
    }

    @TestCase
    func testIntervalTimerLogs(): Unit {
        let script = """
        (cordis::interval 200 (lambda () (cordis::log "info" "tick")))
        """
        let (host, hostT, pluginT) = setupXisp(script)
        @Expect(host.waitFor({ => host.handlerRan }))
        // 等两个 tick（interval 200ms）
        let ticks = host.waitFor({ =>
            synchronized(host.lock) {
                var count = 0
                for (l in host.logs) {
                    if (l == "tick") {
                        count++
                    }
                }
                count >= 2
            }
        })
        @Expect(ticks)
        hostT.close()
        pluginT.close()
    }

    @TestCase
    func testTimeoutCancelCallback(): Unit {
        // timeout 返回 cancel 函数：脚本立即 cancel → 回调不触发
        let script = """
        (define cancel-timer (cordis::timeout 150 (lambda () (cordis::log "info" "fired"))))
        (cancel-timer)
        """
        let (host, hostT, pluginT) = setupXisp(script)
        @Expect(host.waitFor({ => host.handlerRan }))
        sleep(400 * Duration.millisecond)
        // 不应出现 "fired" 日志
        var fired = false
        synchronized(host.lock) {
            for (l in host.logs) {
                if (l == "fired") {
                    fired = true
                }
            }
        }
        @Expect(!fired)
        hostT.close()
        pluginT.close()
    }

    @TestCase
    func testSyntaxErrorThrowsOnInit(): Unit {
        let script = "(cordis::register-handler \"x\" (lambda (m a) (+ 1 "
        let (host, hostT, pluginT) = setupXisp(script)
        // 脚本语法错误 → 初始化抛异常 → 失败标志置位
        @Expect(host.waitFor({ => host.initFailed }))
        @Expect(!host.handlerRan)
        hostT.close()
        pluginT.close()
    }

    @TestCase
    func testPluginIdExposed(): Unit {
        let script = """
        (cordis::register-handler "id" (lambda (method args) (cordis::plugin-id)))
        """
        let (host, hostT, pluginT) = setupXisp(script)
        @Expect(host.waitFor({ => host.handlerRan }))
        let got = invokeRaw(host, "id", "id", Array<JsonValue>())
        match (got) {
            case JsonValue.String(s) => @Expect(s, "xisp-plugin")
            case other => @Fail("expected plugin id string, got ${other}")
        }
        hostT.close()
        pluginT.close()
    }
}
