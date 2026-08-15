package ystyle::cordis_tests

import ystyle::cordis_core.*
import ystyle::cordis_plugin.*
import ystyle::jsonrpc.*
import jsonvalue.*
import std.collection.{HashMap, ArrayList}
import std.io.ByteBuffer
import std.sync.{Mutex, Condition}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 插件 SDK 测试：用 MemoryDuplexTransport 将宿主侧 JsonRpcClient 与
 * 插件侧 PluginRuntime 直接对接，验证完整握手/服务注册/invoke 转发/dispose 流程。
 */

/**
 * 模拟宿主：启动 JsonRpcClient，注册 initialize/provide 处理器，返回控制句柄
 */
private class FakeHost {
    let client: JsonRpcClient
    let lock: Mutex = Mutex()
    let cond: Condition
    var initialized: Bool = false
    var provided: ArrayList<String> = ArrayList()
    var logs: ArrayList<String> = ArrayList()
    var disposed: ArrayList<String> = ArrayList()

    init(client: JsonRpcClient) {
        this.client = client
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    // 等待某条件成立（最多 5 秒）
    func waitFor(predicate: () -> Bool): Bool {
        synchronized(this.lock) {
            var waited = 0
            while (!predicate() && waited < 100) {
                this.cond.wait(timeout: 50 * Duration.millisecond)
                waited++
            }
            predicate()
        }
    }
}

@Test
class PluginRuntimeTest {

    private static func setupHost(): (FakeHost, MemoryDuplexTransport) {
        let (hostT, pluginT) = MemoryDuplexTransport.pair()
        let client = JsonRpcClient(hostT)
        let host = FakeHost(client)

        // 宿主处理 initialize：校验并返回 ok + providers
        client.registerRequestHandler(Methods.INITIALIZE, { req =>
            let providers = HashMap<String, String>()
            providers["db"] = "plugin-db"
            let result = InitializeResult(true, providers)
            Some(JsonValue.fromObject(result))
        })
        // 宿主处理 provide：分配 undo_id 并记录
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
            Some(JsonValue.fromObject(ProvideResult("undo-${host.provided.size}")))
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
        // 宿主处理 dispose 响应/请求
        client.registerRequestHandler(Methods.DISPOSE, { req =>
            synchronized(host.lock) {
                host.disposed.add("dispose-req")
                host.cond.notifyAll()
            }
            None
        })
        client.start()
        (host, pluginT)
    }

    @TestCase
    func testHandshakeAndProvide(): Unit {
        let (host, pluginT) = setupHost()

        spawn {
            PluginRuntime.run(pluginT, "plugin-a", [], ["svc-a", "svc-b"], { ctx =>
                ctx.log("info", "plugin started")
            })
        }

        // 等待宿主收到 initialize 确认（插件在 run 内先握手，再 provide，再执行 handler）
        let ok = host.waitFor({ => host.provided.size >= 2 })
        @Expect(ok)
        @Expect(host.provided, ArrayList<String>.of(["svc-a", "svc-b"]))
        // handler 在握手后执行，ctx.log 证明 handler 已跑
        let logOk = host.waitFor({ => host.logs.size > 0 })
        @Expect(logOk)
        if (host.logs.size > 0) {
            @Expect(host.logs[0], "plugin started")
        }
        // 清理
        host.client.close()
        pluginT.close()
    }

    @TestCase
    func testInvokeForwarding(): Unit {
        // 插件提供 "calc" 服务，宿主通过 invoke 请求调用
        let (host, pluginT) = setupHost()
        spawn {
            PluginRuntime.run(pluginT, "plugin-calc", [], ["calc"], { ctx =>
                ctx.registerHandler("calc", { method, args =>
                    if (method == "add") {
                        let a = match (args[0]) { case JsonValue.Number(n) => n; case _ => 0.0 }
                        let b = match (args[1]) { case JsonValue.Number(n) => n; case _ => 0.0 }
                        JsonValue.Number(a + b)
                    } else {
                        JsonValue.Null
                    }
                })
            })
        }
        // 等待插件 provide 完成
        let ok = host.waitFor({ => host.provided.size >= 1 })
        @Expect(ok)
        // 宿主向插件发 invoke 请求（宿主 → 插件方向用 client.call）
        let result = host.client.call<JsonValue, JsonValue>("invoke",
            params: Some(JsonValue.fromObject(InvokeParams("calc", "add", [
                JsonValue.Number(2.0), JsonValue.Number(3.0)]))))
        match (result) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Number(n) => @Expect(n, 5.0)
                    case _ => @Fail("expected number result")
                }
            case Err(e) => @Fail("invoke failed: ${e}")
        }
        host.client.close()
        pluginT.close()
    }

    @TestCase
    func testDisposeService(): Unit {
        let (host, pluginT) = setupHost()
        spawn {
            PluginRuntime.run(pluginT, "plugin-d", [], ["svc"], { ctx =>
                let undoId = ctx.provide("svc")
                ctx.log("info", "provided:${undoId}")
            })
        }
        let ok = host.waitFor({ => host.provided.size >= 1 })
        @Expect(ok)
        // 宿主向插件发 dispose（携带 undo_id）
        let disposeResult = host.client.call<JsonValue, JsonValue>("dispose",
            params: Some(JsonValue.fromObject(DisposeParams("undo-1"))))
        match (disposeResult) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Boolean(b) => @Expect(b)   // 成功撤销
                    case _ => @Fail("expected bool result")
                }
            case Err(e) => @Fail("dispose failed: ${e}")
        }
        host.client.close()
        pluginT.close()
    }

    @TestCase
    func testPingResponds(): Unit {
        let (host, pluginT) = setupHost()
        spawn {
            PluginRuntime.run(pluginT, "plugin-ping", [], [], { ctx =>
                ctx.log("info", "ready")
            })
        }
        // 等插件起来
        let ok = host.waitFor({ => host.logs.size > 0 })
        @Expect(ok)
        let result = host.client.call("ping")
        match (result) {
            case Ok(v) =>
                match (v) {
                    case JsonValue.Boolean(b) => @Expect(b)
                    case _ => @Fail("expected bool result")
                }
            case Err(e) => @Fail("ping failed: ${e}")
        }
        host.client.close()
        pluginT.close()
    }
}
/**
 * 测试辅助：内存双工管道传输
 *
 * 模拟两个进程间的字节管道：两个 Transport 端点共享两条单向管道，
 * 一端 send 的数据被另一端 receive 读取，反之亦然。用于将
 * JsonRpcClient（宿主侧）与 JsonRpcServer（插件侧）直接对接测试，
 * 无需真实子进程。
 */
public class MemoryDuplexTransport <: Transport {
    // 本端发送方向管道（对端读取）
    private let outPipe: MemoryPipe
    // 本端接收方向管道（对端写入）
    private let inPipe: MemoryPipe
    private var closed: Bool = false
    private let lock: Mutex = Mutex()

    private init(outPipe: MemoryPipe, inPipe: MemoryPipe) {
        this.outPipe = outPipe
        this.inPipe = inPipe
    }

    /**
     * 创建一对互联的传输端点（a.send → b.receive，b.send → a.receive）
     */
    public static func pair(): (MemoryDuplexTransport, MemoryDuplexTransport) {
        let ab = MemoryPipe()   // a → b
        let ba = MemoryPipe()   // b → a
        (MemoryDuplexTransport(ab, ba), MemoryDuplexTransport(ba, ab))
    }

    public func send(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
        }
        this.outPipe.write(data)
    }

    public func receive(): ?Array<Byte> {
        this.inPipe.read()
    }

    public func close(): Unit {
        synchronized(this.lock) {
            if (this.closed) {
                return
            }
            this.closed = true
        }
        // 关闭对端读取方向：通知 EOF
        this.inPipe.close()
    }

    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed
        }
    }
}

/**
 * 单向内存管道：写入方 write，读取方 read（阻塞直到有数据或关闭）
 */
public class MemoryPipe {
    private let buffer = ByteBuffer()
    private let lock: Mutex = Mutex()
    private let cond: Condition
    private var closed: Bool = false

    public init() {
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    public func write(data: Array<Byte>): Unit {
        synchronized(this.lock) {
            this.buffer.write(data)
            this.cond.notifyAll()
        }
    }

    /**
     * 读取数据：有数据立即返回；无数据阻塞等待；关闭且无数据返回 None
     */
    public func read(): ?Array<Byte> {
        synchronized(this.lock) {
            while (this.buffer.remainLength == 0 && !this.closed) {
                if (!this.cond.wait(timeout: Duration.second)) {
                    // 超时继续等待（防御性）
                    continue
                }
            }
            if (this.buffer.remainLength == 0) {
                return None
            }
            let size = this.buffer.remainLength
            let data = Array<Byte>(size, repeat: 0)
            this.buffer.read(data)
            Some(data)
        }
    }

    public func close(): Unit {
        synchronized(this.lock) {
            this.closed = true
            this.cond.notifyAll()
        }
    }

    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed
        }
    }
}
