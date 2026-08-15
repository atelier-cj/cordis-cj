package ystyle::cordis_plugin

import ystyle::cordis_core.*
import ystyle::jsonrpc.*
import ystyle::jsonrpc_stdio.StdioTransport
import jsonvalue.*
import std.sync.Mutex

/**
 * 插件运行时上下文：暴露给插件业务逻辑的 API（docs/design-impl.md §6）
 *
 * 对应 Cordis 的 ctx 对象：服务提供/撤销、可逆效果、日志、宿主调用转发。
 */
public class PluginContext {
    internal let runtime: PluginRuntime

    internal init(runtime: PluginRuntime) {
        this.runtime = runtime
    }

    /**
     * 提供服务（主动注册到宿主），返回宿主分配的 undo_id
     * @param key 服务 Key
     */
    public func provide(key: String): String {
        this.runtime.provideService(key, { => () })
    }

    /**
     * 提供服务（主动注册到宿主），返回宿主分配的 undo_id
     * @param key 服务 Key
     * @param disposer 撤销该服务时执行的回调
     */
    public func provide(key: String, disposer: () -> Unit): String {
        this.runtime.provideService(key, disposer)
    }

    /**
     * 撤销指定服务
     */
    public func dispose(undoId: String): Bool {
        this.runtime.disposeService(undoId)
    }

    /**
     * 注册服务实现：宿主 invoke 转发到本插件时调用
     * @param key 服务 Key（与 provide 的 Key 对应）
     * @param handler (method, args) -> result
     */
    public func registerHandler(key: String, handler: (String, Array<JsonValue>) -> JsonValue): Unit {
        this.runtime.registry.registerHandler(key, handler)
    }

    /**
     * 注册可逆效果：返回 disposer，插件卸载时逆序执行（对应 Cordis ctx.effect）
     */
    public func effect(disposer: () -> Unit): Unit {
        this.runtime.registry.effect(disposer)
    }

    /**
     * 经宿主转发调用其他插件的服务
     * @param service 目标服务 Key
     * @param method 服务方法名
     * @param args 参数列表
     * @return 服务返回值（JSON）
     * @throws Exception 宿主返回错误或调用超时
     */
    public func invoke(service: String, method: String, args: Array<JsonValue>): JsonValue {
        this.runtime.invokeService(service, method, args)
    }

    /**
     * 发送日志到宿主（log 通知）
     */
    public func log(level: String, message: String): Unit {
        this.runtime.sendLog(level, message)
    }
}

/**
 * 插件运行时（docs/design-impl.md §6）
 *
 * 插件 main 入口：PluginRuntime.run(...) 完成握手、注册服务、进入事件循环。
 *
 * 生命周期：
 * 1. 创建 StdioTransport + JsonRpcServer，注册宿主 → 插件处理器
 * 2. server.start() 启动后台接收线程
 * 3. 向宿主发 initialize 请求（握手）
 * 4. 为每个 provide 的 Key 发 provide 请求，宿主返回 undo_id
 * 5. 调用插件业务 handler(ctx)
 * 6. 阻塞等待连接关闭（宿主 terminate 强杀 → stdin EOF → receiveLoop 自动关闭）
 * 7. 逆序撤销所有效果与服务（disposeAll）
 */
public class PluginRuntime {
    internal let registry: ServiceRegistry = ServiceRegistry()
    private let server: JsonRpcServer
    private let pluginId: String
    private let lock: Mutex = Mutex()

    /**
     * 以插件自身 stdio 为传输层启动（插件 main 的标准入口）
     * @param pluginId 插件唯一 ID
     * @param inject 依赖的服务 Key 列表
     * @param provide 提供的服务 Key 列表
     * @param handler 插件业务逻辑（握手与服务注册完成后调用）
     */
    public static func run(pluginId: String, inject: Array<String>, provide: Array<String>,
                           handler: (PluginContext) -> Unit): Unit {
        let transport = StdioTransport()
        let server = JsonRpcServer(transport)
        let runtime = PluginRuntime(server, pluginId)
        runtime.start(inject, provide, handler)
    }

    /**
     * 以自定义传输层启动（测试或特殊传输场景）
     */
    public static func run(transport: Transport, pluginId: String, inject: Array<String>,
                           provide: Array<String>, handler: (PluginContext) -> Unit): Unit {
        let server = JsonRpcServer(transport)
        let runtime = PluginRuntime(server, pluginId)
        runtime.start(inject, provide, handler)
    }

    private init(server: JsonRpcServer, pluginId: String) {
        this.server = server
        this.pluginId = pluginId
    }

    private func start(inject: Array<String>, provide: Array<String>,
                       handler: (PluginContext) -> Unit): Unit {
        this.registerHandlers()
        this.server.start()   // 后台接收线程

        // 握手：向宿主发 initialize 请求
        let initResult = this.server.request<InitializeParams, InitializeResult>(
            Methods.INITIALIZE,
            params: InitializeParams(this.pluginId, inject, provide))
        match (initResult) {
            case Ok(r) =>
                if (!r.ok) {
                    throw Exception("initialize rejected by host: providers=${r.providers}")
                }
            case Err(e) => throw Exception("initialize failed: ${e}")
        }

        // 注册服务：为每个 provide 的 Key 向宿主申请 undo_id
        for (key in provide) {
            this.provideService(key, { => () })
        }

        // 插件业务逻辑
        let ctx = PluginContext(this)
        handler(ctx)

        // 阻塞等待连接关闭（宿主 terminate → stdin EOF → receiveLoop 关闭 server）
        while (!this.server.isClosed()) {
            sleep(100 * Duration.millisecond)
        }

        // 卸载：逆序撤销所有效果与服务
        this.registry.disposeAll()
    }

    private func registerHandlers(): Unit {
        // initialized：宿主确认依赖满足，允许开始工作（通知，无响应）
        this.server.register(Methods.INITIALIZED, { ctx => HandlerResult.ok(JsonValue.Boolean(true)) })
        // dispose：宿主请求撤销指定服务
        this.server.register(Methods.DISPOSE, { ctx => this.handleDispose(ctx) })
        // notify：宿主广播依赖图变化
        this.server.register(Methods.NOTIFY, { ctx => this.handleNotify(ctx) })
        // ping：探活
        this.server.register(Methods.PING, { _ => HandlerResult.ok(JsonValue.Boolean(true)) })
        // invoke：宿主转发的服务调用
        this.server.register(Methods.INVOKE, { ctx => this.handleInvoke(ctx) })
    }

    private func handleDispose(ctx: HandlerContext): HandlerResult {
        match (ctx.getParams<DisposeParams>()) {
            case Some(params) =>
                let removed = this.registry.dispose(params.undoId)
                HandlerResult.ok(JsonValue.Boolean(removed))
            case None => HandlerResult.err(ErrorCodes.INVALID_PARAMS, "invalid dispose params")
        }
    }

    private func handleNotify(ctx: HandlerContext): HandlerResult {
        // 通知无响应；插件可在此实现依赖图变化响应（如注销内部状态）
        HandlerResult.ok(JsonValue.Boolean(true))
    }

    private func handleInvoke(ctx: HandlerContext): HandlerResult {
        match (ctx.getParams<InvokeParams>()) {
            case Some(params) =>
                try {
                    let result = this.registry.invokeHandler(params.service, params.method, params.args)
                    HandlerResult.ok(result)
                } catch (e: Exception) {
                    HandlerResult.err(ErrorCodes.INTERNAL_ERROR, "invoke failed: ${e.message}")
                }
            case None => HandlerResult.err(ErrorCodes.INVALID_PARAMS, "invalid invoke params")
        }
    }

    /**
     * 提供服务：向宿主申请 undo_id 并注册撤销回调
     */
    internal func provideService(key: String, disposer: () -> Unit): String {
        let result = this.server.request<ProvideParams, ProvideResult>(
            Methods.PROVIDE,
            params: ProvideParams(key))
        match (result) {
            case Ok(r) =>
                this.registry.register(r.undoId, disposer)
                r.undoId
            case Err(e) => throw Exception("provide '${key}' failed: ${e}")
        }
    }

    /**
     * 撤销服务
     */
    internal func disposeService(undoId: String): Bool {
        this.registry.dispose(undoId)
    }

    /**
     * 经宿主转发调用其他插件的服务
     */
    internal func invokeService(service: String, method: String, args: Array<JsonValue>): JsonValue {
        let result = this.server.request<InvokeParams, JsonValue>(
            Methods.INVOKE,
            params: InvokeParams(service, method, args))
        match (result) {
            case Ok(v) => v
            case Err(e) => throw Exception("invoke ${service}.${method} failed: ${e}")
        }
    }

    /**
     * 发送日志到宿主
     */
    internal func sendLog(level: String, message: String): Unit {
        this.server.notify<LogParams>(Methods.LOG, params: LogParams(level, message))
    }

    internal prop rpcServer: JsonRpcServer {
        get() {
            this.server
        }
    }
}
