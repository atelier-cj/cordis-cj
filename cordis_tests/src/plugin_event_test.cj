package ystyle::cordis_tests

import ystyle::cordis_plugin.*
import ystyle::cordis_core.*
import ystyle::jsonrpc.*
import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.{HashMap, ArrayList}
import std.sync.{Mutex, Condition}
import std.io.ByteBuffer
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 插件侧事件 API 测试（docs/design-events.md §6）
 *
 * 用 FakeHost 模拟宿主（处理 subscribe/emit/dispatch），
 * 验证 ctx.on / ctx.emit 全链路：
 * 1. 插件 on("evt", listener) → 宿主收到 subscribe，返回订阅 id
 * 2. 插件 emit("evt", args) → 宿主收到 emit 通知
 * 3. 宿主向插件发 events/dispatch → 插件 listener 被调用
 */

/**
 * 模拟宿主：注册 initialize/provide/subscribe/emit 处理器
 * 维护事件订阅，emit 到达时向订阅者（测试中直接调用注入的 dispatch 函数）
 */
private class EventFakeHost {
    let client: JsonRpcClient
    let lock: Mutex = Mutex()
    let cond: Condition
    var provided: ArrayList<String> = ArrayList()
    var subscribed: ArrayList<String> = ArrayList()
    var emitted: ArrayList<String> = ArrayList()
    var dispatched: ArrayList<String> = ArrayList()
    var dispatchFn: ?(String, Array<JsonValue>) -> Unit = None

    init(client: JsonRpcClient) {
        this.client = client
        this.cond = synchronized(this.lock) {
            this.lock.condition()
        }
    }

    func record(list: ArrayList<String>, value: String): Unit {
        synchronized(this.lock) {
            list.add(value)
            this.cond.notifyAll()
        }
    }

    func waitCount(list: ArrayList<String>, n: Int64): Bool {
        synchronized(this.lock) {
            var waited = 0
            while (list.size < n && waited < 100) {
                this.cond.wait(timeout: 50 * Duration.millisecond)
                waited++
            }
            list.size >= n
        }
    }
}

private func setupEventHost(): (EventFakeHost, ExpEventDuplexTransport) {
    let (hostT, pluginT) = ExpEventDuplexTransport.pair()
    let client = JsonRpcClient(hostT, framing: NewlineFraming())
    let host = EventFakeHost(client)

    client.registerRequestHandler(Methods.INITIALIZE, { req =>
        Some(JsonValue.fromObject(InitializeResult(true, HashMap<String, String>())))
    })
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
    // events/subscribe：记录并返回订阅 id
    client.registerRequestHandler(Methods.EVENTS_SUBSCRIBE, { req =>
        match (req.params) {
            case Some(p) =>
                match (JsonValue.toObject<SubscribeParams>(p)) {
                    case params =>
                        synchronized(host.lock) {
                            host.subscribed.add(params.event)
                            host.cond.notifyAll()
                        }
                        Some(JsonValue.fromObject(SubscribeResult("sub-${host.subscribed.size}")))
                }
            case None => Some(JsonValue.fromObject(SubscribeResult("sub-0")))
        }
    })
    // events/emit：记录并调用注入的 dispatch（模拟宿主扇出）
    client.setNotificationCallback({ notif =>
        if (notif.method == Methods.EVENTS_EMIT) {
            match (notif.params) {
                case Some(p) =>
                    match (JsonValue.toObject<EmitParams>(p)) {
                        case params =>
                            synchronized(host.lock) {
                                host.emitted.add(params.event)
                                host.cond.notifyAll()
                            }
                            match (host.dispatchFn) {
                                case Some(fn) => fn(params.event, params.args)
                                case None => ()
                            }
                    }
                case None => ()
            }
        }
    })
    client.start()
    (host, pluginT)
}

@Test
class PluginEventTest {

    @TestCase
    func testOnSubscribesToHost(): Unit {
        // 插件 ctx.on → 宿主收到 subscribe 请求
        let (host, pluginT) = setupEventHost()
        spawn {
            PluginRuntime.run(pluginT, "evt-plugin", [], [], { ctx =>
                let subId = ctx.on("stats/report", { args =>
                    host.record(host.dispatched, "listener-called")
                })
                host.record(host.subscribed, "subId=${subId}")
            })
        }
        // 等待 subscribe 完成（subscribed 有 "stats/report" 且 subId 记录）
        @Expect(host.waitCount(host.subscribed, 1))
        @Expect(host.subscribed[0], "stats/report")
        // subId 记录在 subscribed 列表第二个元素
        @Expect(host.waitCount(host.subscribed, 2))
        @Expect(host.subscribed[1].startsWith("subId=sub-"))
        host.client.close()
        pluginT.close()
    }

    @TestCase
    func testEmitDispatchesToListener(): Unit {
        // 插件 emit → 宿主扇出（测试中注入 dispatchFn）→ 插件 listener 被调用
        let (host, pluginT) = setupEventHost()
        // 宿主侧注入 dispatch：向插件发 events/dispatch 请求
        host.dispatchFn = { event, args =>
            // 通过 pluginT 对端（插件 server）发 dispatch
            // 注：host.client 是宿主连接，pluginT 是插件端——用 host.client 直接调用即可
            let result = host.client.call<JsonValue, JsonValue>(Methods.EVENTS_DISPATCH,
                params: Some(JsonValue.fromObject(DispatchParams(event, args, "emit-1"))))
            match (result) {
                case Ok(_) => ()
                case Err(e) => host.record(host.dispatched, "dispatch-err:${e}")
            }
        }
        spawn {
            PluginRuntime.run(pluginT, "evt-plugin2", [], [], { ctx =>
                ctx.on("greet", { args =>
                    let name = match (args[0]) { case JsonValue.String(s) => s; case _ => "?" }
                    host.record(host.dispatched, "greeted:${name}")
                })
                // 发布事件
                ctx.emit("greet", [JsonValue.String("world")])
            })
        }
        // 等待 listener 被调用（emit → host.dispatchFn → events/dispatch → listener）
        @Expect(host.waitCount(host.dispatched, 1))
        @Expect(host.dispatched[0], "greeted:world")
        // 宿主确实收到了 emit
        @Expect(host.emitted.size >= 1)
        @Expect(host.emitted[0], "greet")
        host.client.close()
        pluginT.close()
    }
}

/**
 * 实验用内存双工管道（独立实现）
 */
internal class ExpEventDuplexTransport <: Transport {
    private let outPipe: ExpEventPipe
    private let inPipe: ExpEventPipe
    private var closed: Bool = false
    private let lock: Mutex = Mutex()

    private init(outPipe: ExpEventPipe, inPipe: ExpEventPipe) {
        this.outPipe = outPipe
        this.inPipe = inPipe
    }

    public static func pair(): (ExpEventDuplexTransport, ExpEventDuplexTransport) {
        let ab = ExpEventPipe()
        let ba = ExpEventPipe()
        (ExpEventDuplexTransport(ab, ba), ExpEventDuplexTransport(ba, ab))
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
        this.inPipe.close()
    }

    public func isClosed(): Bool {
        synchronized(this.lock) {
            this.closed
        }
    }
}

internal class ExpEventPipe {
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

    public func read(): ?Array<Byte> {
        synchronized(this.lock) {
            while (this.buffer.remainLength == 0 && !this.closed) {
                if (!this.cond.wait(timeout: Duration.second)) {
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
