package ystyle::cordis_xisp

import ystyle::cordis_plugin.*
import ystyle::cordis_core.*
import jsonvalue.*
import std.collection.*
import std.sync.Mutex
import std.fs.{File, FSException}
import ystyle::xisp.types.*
import ystyle::xisp.core.eval.*
import ystyle::xisp.core.builtin.BuiltinFunctions
import ystyle::xisp.parser.Parser
import ystyle::xisp.bridge.Bridge
import stdx.serialization.serialization.*

/**
 * Cordis xisp 插件运行时：用 xisp（Lisp）脚本编写 Cordis 插件。
 *
 * 架构：插件进程 = 通用运行时可执行文件，它复用 `PluginRuntime.run` 完成
 * cordis 协议（握手 / provide / invoke 路由 / 事件派发），在业务 handler 里
 * 嵌入 xisp 解释器，把 `PluginContext` 的能力以 `cordis::*` 命名空间绑定注入
 * 脚本环境。脚本顶层表达式求值 = 插件初始化（注册服务 handler 与事件监听器），
 * 之后脚本回调（invoke / 事件 / 定时器）由宿主事件驱动。
 *
 * 与 atelier PTC 是同一套「宿主把能力以绑定形式注入 xisp 环境」模式的另一个
 * 投影：atelier 是宿主进程内嵌 xisp 跑一段程序；这里是插件进程内嵌 xisp 跑
 * 一个长驻脚本 + 事件驱动。
 *
 * 并发模型：
 * - xisp `Environment` 非线程安全 → 所有进脚本的调用（handler / 监听器 /
 *   定时器回调）经 `scriptLock` 串行化；
 * - 每次脚本调用使用**独立** `Evaluator` 实例（避免求值器实例状态跨线程竞态）；
 * - 同步请求类绑定（invoke / serial / bail / waterfall）在等待宿主响应前
 *   **释放脚本锁**，收到响应后重新获取——解开「脚本回调内嵌套调用自己插件
 *   服务」的跨线程死锁（cordis 的 INVOKE 处理在独立线程执行，若持锁等待，
 *   宿主把回调派发回本插件时会阻塞在同一把锁上）。
 *
 * 已知边界（文档化）：
 * - 同步请求等待窗口内，其他回调可能并发进入脚本（共享 `Environment` 的
 *   并发访问由脚本自行负责；纯函数回调安全）；
 * - 脚本回调默认无超时（与原生仓颉插件一致：宿主 invoke 超时会放弃等待，
 *   但脚本线程会继续跑完）。
 */
public class XispPluginRuntime {

    private let ctx: PluginContext
    private let pluginId: String
    private let env: Environment
    // 脚本调用串行化锁（可重入；同步请求等待期间主动释放，见类注释）
    private let scriptLock: Mutex = Mutex()
    // 宿主声明的 provide 清单（entry.provide，经环境变量下发）。
    // 脚本 register-handler 的 Key 与之比对，缺实现时留痕（宿主按声明等待注册，
    // 静默缺失会表现为 invoke 找不到服务）。
    private let declaredProvide: Array<String>
    // 脚本已注册的 handler Key（供声明校验）
    private let registeredKeys: ArrayList<String> = ArrayList<String>()

    private init(ctx: PluginContext, pluginId: String, declaredProvide: Array<String>) {
        this.ctx = ctx
        this.pluginId = pluginId
        this.declaredProvide = declaredProvide
        this.env = Environment()
        this.registerBindings()
    }

    /**
     * 标准入口：完整插件生命周期（main 用）。
     *
     * @param pluginId 插件 ID（与 cordis.toml entry.id 一致）
     * @param inject 依赖的服务 Key 列表（与 entry.inject 一致）
     * @param provide 提供的服务 Key 列表（与 entry.provide 一致；用于初始化声明
     *                与「脚本是否实现了全部声明服务」的校验）
     * @param scriptPath .lisp 插件脚本路径
     */
    public static func run(pluginId: String, inject: Array<String>, provide: Array<String>,
                           scriptPath: String): Unit {
        PluginRuntime.run(pluginId, inject, provide, { ctx =>
            let rt = XispPluginRuntime(ctx, pluginId, provide)
            rt.loadScript(scriptPath)
        })
    }

    /**
     * 绑定到已就绪的 PluginContext（嵌入/测试用）：
     * 构造运行时并加载插件脚本，脚本顶层注册的 handler / 监听器
     * 接入 cordis 协议。
     *
     * @param ctx 已握手的插件上下文（PluginRuntime 的 handler 内）
     * @param pluginId 插件 ID（cordis::plugin-id 返回）
     * @param scriptPath .lisp 插件脚本路径
     * @param declaredProvide 宿主声明的 provide 清单（缺省空 = 不校验）
     * @return 运行时实例（保留引用以便后续按需调用脚本能力）
     */
    public static func attach(ctx: PluginContext, pluginId: String, scriptPath: String,
                              declaredProvide!: Array<String> = Array<String>()): XispPluginRuntime {
        let rt = XispPluginRuntime(ctx, pluginId, declaredProvide)
        rt.loadScript(scriptPath)
        rt
    }

    /**
     * 同 attach，从脚本文本加载（测试友好）。
     */
    public static func attachText(ctx: PluginContext, pluginId: String, scriptText: String,
                                  declaredProvide!: Array<String> = Array<String>()): XispPluginRuntime {
        let rt = XispPluginRuntime(ctx, pluginId, declaredProvide)
        rt.loadScriptText(scriptText)
        rt
    }

    /**
     * 加载并执行插件脚本（初始化）。
     *
     * 脚本顶层求值即插件初始化：注册服务 handler / 事件监听器 / 定时器等。
     * 顶层表达式出错（语法错误 / 运行时错误）抛异常 → main 打印 stderr 退出，
     * 宿主按崩溃自愈处理。
     *
     * @param scriptPath .lisp 脚本路径
     */
    public func loadScript(scriptPath: String): Unit {
        let text = try {
            String.fromUtf8(File.readFrom(scriptPath))
        } catch (e: FSException) {
            throw Exception("xisp plugin script not found: ${scriptPath} (${e.message})")
        }
        this.loadScriptText(text)
    }

    /**
     * 从脚本文本初始化（测试友好，绕过文件系统）。
     */
    public func loadScriptText(scriptText: String): Unit {
        let parsed = Parser.parseChecked(scriptText)
        match (parsed.error) {
            case Some(e) => throw Exception("xisp plugin script syntax error: ${e.message}")
            case None => ()
        }
        let evaluator = Evaluator(this.env)
        synchronized(this.scriptLock) {
            for (expr in parsed.exprs) {
                let result = evaluator.eval(expr)
                match (result) {
                    case LispValue.Error(e) => throw Exception("xisp plugin init error: ${e.message}")
                    case _ => ()
                }
            }
        }
        this.warnUnimplementedProvide()
    }

    /**
     * 校验宿主声明的 provide：声明的服务 Key 必须有脚本 handler 实现。
     *
     * 宿主侧 awaitActive 按 entry.provide 等待注册，缺失实现时握手会超时
     * （现象是插件起不来而不是 invoke 报错），因此在插件侧主动留痕。
     * 只诊断不失败：脚本可能在运行期（事件/定时器回调里）才注册 handler。
     *
     * 诊断走 stderr：stdout 是插件↔宿主的协议帧通道，stderr 由宿主
     * PluginManager.forwardStderr 转发进宿主日志。
     */
    private func warnUnimplementedProvide(): Unit {
        if (this.declaredProvide.size == 0) {
            return
        }
        let missing = ArrayList<String>()
        synchronized(this.scriptLock) {
            for (key in this.declaredProvide) {
                if (!this.registeredKeys.contains(key)) {
                    missing.add(key)
                }
            }
        }
        if (missing.size > 0) {
            eprintln("[cordis-xisp] plugin '${this.pluginId}' declares provide but has no handler registered at init: " +
                String.join(missing.toArray(), delimiter: ", "))
        }
    }

    // ─────────────────────────── 绑定注册 ───────────────────────────

    private func registerBindings(): Unit {
        // 纯函数子集 + 输出接管：println 等进宿主日志通道。
        // stdout 是插件↔宿主的协议帧通道，脚本打印绝不能落进程 stdout。
        BuiltinFunctions.registerPure(this.env, output: Some({ s => this.ctx.log("info", s) }))

        Bridge.registerFunc(this.env, "cordis::register-handler", { args => this.bindingRegisterHandler(args) })
        Bridge.registerFunc(this.env, "cordis::on", { args => this.bindingOn(args, false) })
        Bridge.registerFunc(this.env, "cordis::once", { args => this.bindingOn(args, true) })
        Bridge.registerFunc(this.env, "cordis::emit", { args => this.bindingEmit(args) })
        Bridge.registerFunc(this.env, "cordis::serial", { args => this.bindingEmitSync(args, EventMode.SERIAL) })
        Bridge.registerFunc(this.env, "cordis::bail", { args => this.bindingEmitSync(args, EventMode.BAIL) })
        Bridge.registerFunc(this.env, "cordis::waterfall", { args => this.bindingEmitSync(args, EventMode.WATERFALL) })
        Bridge.registerFunc(this.env, "cordis::invoke", { args => this.bindingInvoke(args) })
        Bridge.registerFunc(this.env, "cordis::log", { args => this.bindingLog(args) })
        Bridge.registerFunc(this.env, "cordis::provide", { args => this.bindingProvide(args) })
        Bridge.registerFunc(this.env, "cordis::dispose", { args => this.bindingDispose(args) })
        Bridge.registerFunc(this.env, "cordis::effect", { args => this.bindingEffect(args) })
        Bridge.registerFunc(this.env, "cordis::timeout", { args => this.bindingTimer(args, TimerKind.Timeout) })
        Bridge.registerFunc(this.env, "cordis::interval", { args => this.bindingTimer(args, TimerKind.Interval) })
        Bridge.registerFunc(this.env, "cordis::throttle", { args => this.bindingTimer(args, TimerKind.Throttle) })
        Bridge.registerFunc(this.env, "cordis::debounce", { args => this.bindingTimer(args, TimerKind.Debounce) })
        Bridge.registerFunc(this.env, "cordis::config", { _ => this.bindingConfig() })
        Bridge.registerFunc(this.env, "cordis::plugin-id", { _ => this.bindingPluginId() })
    }

    // ─────────────────────────── 脚本调用 ───────────────────────────

    /**
     * 宿主侧调用脚本注册的函数值（lambda）。
     *
     * 构造表达式树 `(apply fn (quote args))` 交给求值器执行——xisp 没有公开的
     * 「调用函数值」API，但 `apply` 特殊形式 + `quote` 接受任意函数值，且
     * Procedure / Closure / NativeFunc 值在求值器里自求值，这条路被 PTC 实测
     * 锁定过（错误即值短路传播等语义保持一致）。
     *
     * @param fn 脚本注册的函数值（LispValue.Procedure / Closure / NativeFunc）
     * @param args 实参列表（求值前不经过求值器，直接作为值）
     * @return 求值结果；脚本错误以 `LispValue.Error` 值返回，不抛异常
     */
    private func callScript(fn: LispValue, args: ArrayList<LispValue>): LispValue {
        let evaluator = Evaluator(this.env)
        let expr = XispPluginRuntime.applyExpr(fn, args)
        synchronized(this.scriptLock) {
            evaluator.eval(expr)
        }
    }

    /**
     * 构造 `(apply fn (quote (a b c)))` 表达式树。
     */
    private static func applyExpr(fn: LispValue, args: ArrayList<LispValue>): LispValue {
        var argList: LispValue = LispValue.Nil
        var i = args.size
        while (i > 0) {
            i = i - 1
            argList = consValue(args[i], argList)
        }
        let quoted = consValue(Symbol("quote"), consValue(argList, LispValue.Nil))
        consValue(Symbol("apply"), consValue(fn, consValue(quoted, LispValue.Nil)))
    }

    /**
     * 在「已持有脚本锁」的上下文中执行同步请求：等待宿主响应前释放锁，
     * 响应后重新获取。异常路径同样恢复锁（后续回调依赖它）。
     *
     * 前提：调用方必须已持有 scriptLock（即正在脚本求值栈上）。
     * 具体返回类型版本（泛型版本触发编译器语义错误，见 git 记录）。
     */
    private func withRelinquishedLockValue(body: () -> JsonValue): JsonValue {
        this.scriptLock.unlock()
        try {
            let r = body()
            this.scriptLock.lock()
            r
        } catch (e: Exception) {
            this.scriptLock.lock()
            throw e
        }
    }

    /**
     * 同 withRelinquishedLockValue，返回可选值版本（serial/bail/waterfall）。
     */
    private func withRelinquishedLockOpt(body: () -> ?JsonValue): ?JsonValue {
        this.scriptLock.unlock()
        try {
            let r = body()
            this.scriptLock.lock()
            r
        } catch (e: Exception) {
            this.scriptLock.lock()
            throw e
        }
    }

    // ─────────────────────────── 绑定实现 ───────────────────────────

    /**
     * (cordis::register-handler "key" (lambda (method args) ...)) -> #t
     *
     * 注册服务实现；宿主 invoke 转发到本插件时调用脚本 lambda。
     * 脚本 lambda 签名：(lambda (method args) result)，args 为参数列表。
     * 返回值必须是可序列化为 JSON 的值（nil / 布尔 / 数字 / 字符串 / 列表 /
     * 哈希表）；错误值或不可序列化值 → 抛异常（cordis 侧按 INVOKE-ERROR 透传）。
     */
    private func bindingRegisterHandler(args: ArrayList<LispValue>): LispValue {
        if (args.size < 2) {
            return arityError("cordis::register-handler expects (key, handler)")
        }
        match (args[0]) {
            case Str(key) =>
                let fn = args[1]
                synchronized(this.scriptLock) {
                    if (!this.registeredKeys.contains(key)) {
                        this.registeredKeys.add(key)
                    }
                }
                this.ctx.registerHandler(key, { method, jsonArgs =>
                    let callArgs = ArrayList<LispValue>()
                    callArgs.add(Str(method))
                    callArgs.add(XispPluginRuntime.lispArgsFromJson(jsonArgs))
                    let result = this.callScript(fn, callArgs)
                    match (JsonBridge.toJson(result)) {
                        case Some(j) => j
                        case None =>
                            match (JsonBridge.errorMessage(result)) {
                                case Some(msg) => throw Exception("xisp handler '${key}' error: ${msg}")
                                case None => throw Exception("xisp handler '${key}' returned a non-JSON value")
                            }
                    }
                })
                LispValue.Boolean(true)
            case _ => typeError("cordis::register-handler: key must be a string")
        }
    }

    /**
     * (cordis::on "event" (lambda (args) ...)) -> 订阅 id
     * (cordis::once "event" (lambda (args) ...)) -> 订阅 id
     *
     * 订阅事件（emit 模式）；监听器脚本 lambda 签名：(lambda (args) ...)。
     * 监听器返回值在 emit 模式下被忽略；订阅是效果，插件卸载自动退订。
     */
    private func bindingOn(args: ArrayList<LispValue>, once: Bool): LispValue {
        if (args.size < 2) {
            return arityError("cordis::on expects (event, listener)")
        }
        match (args[0]) {
            case Str(event) =>
                let fn = args[1]
                let listener = { jsonArgs: Array<JsonValue> =>
                    let callArgs = ArrayList<LispValue>()
                    callArgs.add(XispPluginRuntime.lispArgsFromJson(jsonArgs))
                    let _ = this.callScript(fn, callArgs)
                    ()
                }
                let subscriptionId = if (once) {
                    this.ctx.once(event, listener)
                } else {
                    this.ctx.on(event, listener)
                }
                Str(subscriptionId)
            case _ => typeError("cordis::on: event must be a string")
        }
    }

    /**
     * (cordis::emit "event" args-list) -> #t
     *
     * 发布事件（emit 模式）：通知宿主扇出，不等待订阅者。
     */
    private func bindingEmit(args: ArrayList<LispValue>): LispValue {
        if (args.size < 1) {
            return arityError("cordis::emit expects (event, args?)")
        }
        match (args[0]) {
            case Str(event) =>
                let jsonArgs = XispPluginRuntime.jsonArgsArg(args, 1, "cordis::emit")
                this.ctx.emit(event, jsonArgs)
                LispValue.Boolean(true)
            case _ => typeError("cordis::emit: event must be a string")
        }
    }

    /**
     * (cordis::serial "event" args-list) -> 结果
     * (cordis::bail "event" args-list) -> 结果
     * (cordis::waterfall "event" args-list) -> 结果
     *
     * 同步派发：请求宿主按模式派发并等待聚合结果。等待响应前释放脚本锁
     * （防止宿主把下游回调派发回本插件时死锁）。
     */
    private func bindingEmitSync(args: ArrayList<LispValue>, mode: String): LispValue {
        if (args.size < 1) {
            return arityError("cordis::${mode} expects (event, args?)")
        }
        match (args[0]) {
            case Str(event) =>
                let jsonArgs = XispPluginRuntime.jsonArgsArg(args, 1, "cordis::${mode}")
                let result: ?JsonValue = this.withRelinquishedLockOpt({
                    => if (mode == EventMode.SERIAL) {
                        this.serialRemote(event, jsonArgs)
                    } else if (mode == EventMode.BAIL) {
                        this.bailRemote(event, jsonArgs)
                    } else {
                        this.waterfallRemote(event, jsonArgs)
                    }
                })
                match (result) {
                    case Some(v) => JsonBridge.toLisp(v)
                    case None => LispValue.Nil
                }
            case _ => typeError("cordis::${mode}: event must be a string")
        }
    }

    /**
     * (cordis::invoke "service" "method" args-list) -> 结果
     *
     * 经宿主转发调用其他插件的服务。等待响应前释放脚本锁
     * （宿主可能把调用链派发回本插件，持锁等待即死锁）。
     */
    private func bindingInvoke(args: ArrayList<LispValue>): LispValue {
        if (args.size < 2) {
            return arityError("cordis::invoke expects (service, method, args?)")
        }
        match (args[0]) {
            case Str(service) =>
                match (args[1]) {
                    case Str(method) =>
                        let jsonArgs = XispPluginRuntime.jsonArgsArg(args, 2, "cordis::invoke")
                        let result = this.withRelinquishedLockValue({
                            => this.invokeRemote(service, method, jsonArgs)
                        })
                        JsonBridge.toLisp(result)
                    case _ => typeError("cordis::invoke: method must be a string")
                }
            case _ => typeError("cordis::invoke: service must be a string")
        }
    }

    /**
     * (cordis::log "level" "message") -> #t
     */
    private func bindingLog(args: ArrayList<LispValue>): LispValue {
        if (args.size < 2) {
            return arityError("cordis::log expects (level, message)")
        }
        match (args[0]) {
            case Str(level) =>
                match (args[1]) {
                    case Str(message) =>
                        this.ctx.log(level, message)
                        LispValue.Boolean(true)
                    case _ => typeError("cordis::log: message must be a string")
                }
            case _ => typeError("cordis::log: level must be a string")
        }
    }

    /**
     * (cordis::provide "key") -> undo-id
     *
     * 运行时向宿主注册服务（宿主按 entry.provide 静态声明已建期望，
     * 这里把声明落实为协议请求）。
     */
    private func bindingProvide(args: ArrayList<LispValue>): LispValue {
        if (args.size < 1) {
            return arityError("cordis::provide expects (key)")
        }
        match (args[0]) {
            case Str(key) => Str(this.ctx.provide(key))
            case _ => typeError("cordis::provide: key must be a string")
        }
    }

    /**
     * (cordis::dispose "undo-id") -> #t / #f
     */
    private func bindingDispose(args: ArrayList<LispValue>): LispValue {
        if (args.size < 1) {
            return arityError("cordis::dispose expects (undo-id)")
        }
        match (args[0]) {
            case Str(undoId) => LispValue.Boolean(this.ctx.dispose(undoId))
            case _ => typeError("cordis::dispose: undo-id must be a string")
        }
    }

    /**
     * (cordis::effect (lambda () ...)) -> #t
     *
     * 注册可逆效果：插件卸载时逆序执行 disposer 脚本。
     */
    private func bindingEffect(args: ArrayList<LispValue>): LispValue {
        if (args.size < 1) {
            return arityError("cordis::effect expects (disposer)")
        }
        let fn = args[0]
        this.ctx.effect({ =>
            let _ = this.callScript(fn, ArrayList<LispValue>())
            ()
        })
        LispValue.Boolean(true)
    }

    /**
     * (cordis::timeout ms (lambda () ...)) -> cancel 函数
     * (cordis::interval ms (lambda () ...)) -> cancel 函数
     * (cordis::throttle ms (lambda () ...)) -> cancel 函数
     * (cordis::debounce ms (lambda () ...)) -> cancel 函数
     *
     * 定时器（std.sync.Timer，可撤销）：返回的 cancel 是一个宿主函数值，
     * 脚本里调用 (cancel) 即可撤销定时器。
     */
    private func bindingTimer(args: ArrayList<LispValue>, kind: TimerKind): LispValue {
        if (args.size < 2) {
            return arityError("cordis::timer expects (ms, callback)")
        }
        match (args[0]) {
            case LispValue.Int(ms) =>
                let fn = args[1]
                let callback = { =>
                    let _ = this.callScript(fn, ArrayList<LispValue>())
                    ()
                }
                let cancel: () -> Unit = match (kind) {
                    case TimerKind.Timeout => this.ctx.timeout(ms, callback)
                    case TimerKind.Interval => this.ctx.interval(ms, callback)
                    case TimerKind.Throttle => this.ctx.throttle(ms, callback)
                    case TimerKind.Debounce => this.ctx.debounce(ms, callback)
                }
                // 把 cancel 函数包装成宿主函数值返回给脚本
                NativeFunc({ _ =>
                    cancel()
                    LispValue.Boolean(true)
                })
            case _ => typeError("cordis::timer: ms must be an integer")
        }
    }

    /**
     * (cordis::config) -> 插件私有配置（哈希表 / 标量）
     */
    private func bindingConfig(): LispValue {
        this.dataModelToLisp(this.ctx.config)
    }

    /**
     * (cordis::plugin-id) -> 插件 ID 字符串
     */
    private func bindingPluginId(): LispValue {
        Str(this.pluginId)
    }

    // ─────────────────────────── 辅助 ───────────────────────────

    /**
     * PluginContext.invoke 的非泛型包装。
     *
     * 带泛型重载的 ctx 方法在 lambda 上下文内直接调用会触发编译器
     * 语义错误（cjc 1.1.3 实测），统一经此包装后在 lambda 中使用。
     */
    private func invokeRemote(service: String, method: String, args: Array<JsonValue>): JsonValue {
        let r = this.ctx.invoke(service, method, args)
        r
    }

    /**
     * 同 invokeRemote：serial 非泛型包装。
     */
    private func serialRemote(event: String, args: Array<JsonValue>): ?JsonValue {
        let r = this.ctx.serial(event, args)
        r
    }

    /**
     * 同 invokeRemote：bail 非泛型包装。
     */
    private func bailRemote(event: String, args: Array<JsonValue>): ?JsonValue {
        let r = this.ctx.bail(event, args)
        r
    }

    /**
     * 同 invokeRemote：waterfall 非泛型包装。
     */
    private func waterfallRemote(event: String, args: Array<JsonValue>): ?JsonValue {
        let r = this.ctx.waterfall(event, args)
        r
    }

    /**
     * 取列表参数并转 JSON 数组（非列表标量包装为单元素数组；缺省为空数组）。
     */
    private static func jsonArgsArg(args: ArrayList<LispValue>, idx: Int64, name: String): Array<JsonValue> {
        if (idx >= args.size) {
            return Array<JsonValue>()
        }
        match (JsonBridge.toJson(args[idx])) {
            case Some(JsonValue.Array(items)) => items.toArray()
            case Some(j) => Array<JsonValue>(1, { _ => j })
            case None => throw Exception("${name}: argument ${idx} is not a JSON-serializable list")
        }
    }

    /**
     * cordis 回调的 JSON 参数数组 → xisp 列表（供脚本 lambda 的 args 参数）。
     *
     * cordis 的 handler / listener 参数是 `Array<JsonValue>`，先转
     * `JsonValue.Array`（需 ArrayList）再经 JsonBridge 转 Lisp 列表。
     */
    private static func lispArgsFromJson(jsonArgs: Array<JsonValue>): LispValue {
        let items = ArrayList<JsonValue>()
        for (j in jsonArgs) {
            items.add(j)
        }
        JsonBridge.toLisp(JsonValue.Array(items))
    }

    /**
     * DataModel（stdx 中间表示）→ LispValue。
     */
    private func dataModelToLisp(dm: DataModel): LispValue {
        match (dm) {
            case _: DataModelNull => LispValue.Nil
            case b: DataModelBool => LispValue.Boolean(b.getValue())
            case i: DataModelInt => LispValue.Int(i.getValue())
            case f: DataModelFloat => LispValue.Float(f.getValue())
            case s: DataModelString => LispValue.Str(s.getValue())
            case seq: DataModelSeq =>
                let items = ArrayList<LispValue>()
                for (item in seq.getItems()) {
                    items.add(this.dataModelToLisp(item))
                }
                listFrom(items)
            case st: DataModelStruct =>
                let bindings = HashMap<String, LispValue>()
                for (f in st.getFields()) {
                    bindings.add(f.getName(), this.dataModelToLisp(f.getData()))
                }
                LispValue.HashMap(bindings)
            case _ => LispValue.Nil
        }
    }

    private static func arityError(message: String): LispValue {
        LispValue.Error(XispError(ErrorType.ArityMismatch, message))
    }

    private static func typeError(message: String): LispValue {
        LispValue.Error(XispError(ErrorType.TypeError, message))
    }

    private static func listFrom(items: ArrayList<LispValue>): LispValue {
        var result: LispValue = LispValue.Nil
        var i = items.size
        while (i > 0) {
            i = i - 1
            result = consValue(items[i], result)
        }
        result
    }
}

/**
 * 定时器种类（绑定分发用）。
 */
private enum TimerKind {
    | Timeout
    | Interval
    | Throttle
    | Debounce
}
