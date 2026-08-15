package ystyle::cordis_host

import ystyle::cordis_core.*
import ystyle::jsonrpc.*
import jsonvalue.*
import std.collection.{HashMap, ArrayList, HashSet}
import std.sync.Mutex

/**
 * 宿主协调器（docs/design-impl.md §5、§6.2）
 *
 * 职责：
 * - launchPlugin：拉起插件并注册宿主侧 RPC 处理器（initialize/provide/log/invoke）
 * - reconcile：读期望 → diff → 拓扑排序启动 → 先加后删 → 崩溃自愈
 *
 * 依赖握手流程（docs/design-impl.md §4.2）：
 * 1. 插件启动后向宿主发 initialize 请求（inject/provide 清单）
 * 2. 宿主检查 inject 依赖是否全部就绪，返回 InitializeResult(ok, providers)
 * 3. 插件为每个 provide 的 Key 发 provide 请求，宿主分配 undo_id
 */
public class PluginHost {
    public let state: HostState = HostState()
    public let manager: PluginManager
    public let eventRegistry: EventRegistry = EventRegistry()
    private let logger: (String, String) -> Unit
    private var undoCounter: Int64 = 0
    private var emitCounter: Int64 = 0
    private let lock: Mutex = Mutex()

    public init(manager: PluginManager, logger: (String, String) -> Unit) {
        this.manager = manager
        this.logger = logger
    }

    public init(manager: PluginManager) {
        this.manager = manager
        this.logger = { _, _ => () }
    }

    /**
     * 拉起插件并注册宿主侧 RPC 处理器
     * @return 新实例（Starting 状态）
     */
    public func launchPlugin(entry: PluginEntry): PluginInstance {
        let instance = this.manager.launch(entry)
        this.registerHostHandlers(instance)
        this.state.addInstance(instance)
        instance
    }

    /**
     * 注册宿主 → 插件连接上的处理器（插件发起的请求）
     */
    private func registerHostHandlers(instance: PluginInstance): Unit {
        let client = instance.client
        let providerId = instance.entry.id

        // 插件 → 宿主：initialize 握手
        client.registerRequestHandler(Methods.INITIALIZE, { req =>
            match (req.params) {
                case Some(p) =>
                    try {
                        let params = JsonValue.toObject<InitializeParams>(p)
                        // 检查依赖是否全部就绪
                        let missing = this.checkMissing(params.inject)
                        if (missing.size == 0) {
                            synchronized(this.lock) {
                                instance.status = InstanceStatus.Active
                            }
                            let providers = this.snapshotProviders(params.inject)
                            Some(JsonValue.fromObject(InitializeResult(true, providers)))
                        } else {
                            this.logger(providerId, "initialize rejected: missing deps ${missing}")
                            Some(JsonValue.fromObject(InitializeResult(false, HashMap<String, String>())))
                        }
                    } catch (e: Exception) {
                        this.logger(providerId, "initialize parse error: ${e.message}")
                        Some(JsonValue.fromObject(InitializeResult(false, HashMap<String, String>())))
                    }
                case None =>
                    Some(JsonValue.fromObject(InitializeResult(false, HashMap<String, String>())))
            }
        })

        // 插件 → 宿主：provide 注册服务
        client.registerRequestHandler(Methods.PROVIDE, { req =>
            match (req.params) {
                case Some(p) =>
                    try {
                        let params = JsonValue.toObject<ProvideParams>(p)
                        let undoId = this.allocateUndoId()
                        this.state.registerService(params.key, providerId, undoId)
                        this.logger(providerId, "provide ${params.key} -> ${undoId}")
                        synchronized(this.lock) {
                            instance.provides[params.key] = undoId
                        }
                        Some(JsonValue.fromObject(ProvideResult(undoId)))
                    } catch (e: Exception) {
                        this.logger(providerId, "provide error: ${e.message}")
                        None
                    }
                case None => None
            }
        })

        // 插件 → 宿主：通知（log / events/emit）
        // 注意：setNotificationCallback 只能设置一个回调，合并处理多种通知
        client.setNotificationCallback({ notif =>
            if (notif.method == Methods.LOG) {
                match (notif.params) {
                    case Some(p) =>
                        match (JsonValue.toObject<LogParams>(p)) {
                            case lp => this.logger(providerId, "[${lp.level}] ${lp.message}")
                        }
                    case None => ()
                }
            } else if (notif.method == Methods.EVENTS_EMIT) {
                match (notif.params) {
                    case Some(p) =>
                        try {
                            let params = JsonValue.toObject<EmitParams>(p)
                            let emitId = this.allocateEmitId()
                            let delivered = this.eventRegistry.dispatchEmit(params, emitId)
                            this.logger(providerId, "emit ${params.event} -> ${delivered} subscribers")
                        } catch (e: Exception) {
                            this.logger(providerId, "emit error: ${e.message}")
                        }
                    case None => ()
                }
            }
        })

        // 事件总线：插件 → 宿主 订阅 / 退订（docs/design-events.md §5.3）
        client.registerRequestHandler(Methods.EVENTS_SUBSCRIBE, { req =>
            match (req.params) {
                case Some(p) =>
                    try {
                        let params = JsonValue.toObject<SubscribeParams>(p)
                        let subscriptionId = this.eventRegistry.subscribe(params.event, providerId, instance)
                        this.logger(providerId, "subscribe ${params.event} -> ${subscriptionId}")
                        Some(JsonValue.fromObject(SubscribeResult(subscriptionId)))
                    } catch (e: Exception) {
                        this.logger(providerId, "subscribe error: ${e.message}")
                        None
                    }
                case None => None
            }
        })
        client.registerRequestHandler(Methods.EVENTS_UNSUBSCRIBE, { req =>
            match (req.params) {
                case Some(p) =>
                    try {
                        let params = JsonValue.toObject<UnsubscribeParams>(p)
                        let removed = this.eventRegistry.unsubscribe(params.subscriptionId)
                        Some(JsonValue.Boolean(removed))
                    } catch (e: Exception) {
                        Some(JsonValue.Boolean(false))
                    }
                case None => Some(JsonValue.Boolean(false))
            }
        })
    }

    private func allocateEmitId(): String {
        synchronized(this.lock) {
            this.emitCounter++
            "emit-${this.emitCounter}"
        }
    }

    /**
     * 检查依赖：返回缺失的服务 Key 列表
     */
    private func checkMissing(inject: Array<String>): ArrayList<String> {
        let missing = ArrayList<String>()
        for (key in inject) {
            if (!this.state.hasService(key)) {
                missing.add(key)
            }
        }
        missing
    }

    /**
     * 生成 providers 快照：serviceKey -> providerId
     */
    private func snapshotProviders(inject: Array<String>): HashMap<String, String> {
        let providers = HashMap<String, String>()
        synchronized(this.state.lock) {
            for (key in inject) {
                if (this.state.serviceIndex.contains(key)) {
                    providers[key] = this.state.serviceIndex[key]
                }
            }
        }
        providers
    }

    private func allocateUndoId(): String {
        synchronized(this.lock) {
            this.undoCounter++
            "undo-${this.undoCounter}"
        }
    }

    /**
     * 调谐一轮：读期望 → diff → 拓扑启动 → 先加后删 → 崩溃自愈
     * @param configPath TOML 配置路径
     */
    public func reconcile(configPath: String): Unit {
        let config = ConfigLoader.load(configPath)
        // 重建 desired（enabled=true 的条目）
        synchronized(this.state.lock) {
            this.state.desired = HashMap<String, PluginEntry>()
            for (entry in config.entries) {
                if (entry.enabled) {
                    this.state.desired[entry.id] = entry
                }
            }
        }
        this.reconcileDesired()
    }

    /**
     * 对当前 desired 状态执行一次调谐（测试可直接调用）
     */
    public func reconcileDesired(): Unit {
        // 1. 计算 diff
        let toRemove = this.computeToRemove()
        let toAdd = this.computeToAdd()
        let toUpdate = this.computeToUpdate()

        // 2. 先加后删：新进程握手成功后再杀旧进程（服务不中断）
        for (entry in toAdd) {
            try {
                this.launchPlugin(entry)
                this.logger(entry.id, "launched")
            } catch (e: Exception) {
                this.logger(entry.id, "launch failed: ${e.message}")
            }
        }
        for (id in toRemove) {
            this.removePlugin(id)
        }
        for (entry in toUpdate) {
            this.removePlugin(entry.id)
            try {
                this.launchPlugin(entry)
                this.logger(entry.id, "updated")
            } catch (e: Exception) {
                this.logger(entry.id, "update launch failed: ${e.message}")
            }
        }

        // 3. 崩溃自愈：desired 存在但进程已退出 → 重新拉起
        this.healCrashed()
    }

    private func computeToRemove(): ArrayList<String> {
        let result = ArrayList<String>()
        synchronized(this.state.lock) {
            for (id in this.state.actual.keys()) {
                if (!this.state.desired.contains(id)) {
                    result.add(id)
                }
            }
        }
        result
    }

    private func computeToAdd(): ArrayList<PluginEntry> {
        let result = ArrayList<PluginEntry>()
        synchronized(this.state.lock) {
            for ((id, entry) in this.state.desired) {
                if (!this.state.actual.contains(id)) {
                    result.add(entry)
                }
            }
        }
        // 拓扑排序：依赖方后启动
        this.topoSort(result)
        return result
    }

    private func computeToUpdate(): ArrayList<PluginEntry> {
        let result = ArrayList<PluginEntry>()
        synchronized(this.state.lock) {
            for ((id, entry) in this.state.desired) {
                if (this.state.actual.contains(id)) {
                    let instance = this.state.actual[id]
                    if (this.entryChanged(instance.entry, entry)) {
                        result.add(entry)
                    }
                }
            }
        }
        result
    }

    private func entryChanged(old: PluginEntry, new: PluginEntry): Bool {
        old.source != new.source ||
        old.args != new.args ||
        JsonValue.fromDataModel(old.config).stringify() != JsonValue.fromDataModel(new.config).stringify()
    }

    /**
     * 移除插件：终止进程 + 清理服务注册表
     */
    public func removePlugin(id: String): Unit {
        let instance = this.state.getInstance(id)
        match (instance) {
            case Some(inst) =>
                this.logger(id, "removing")
                this.eventRegistry.unsubscribeAll(id)   // 清理事件订阅（docs/design-events.md §8）
                this.state.clearServicesByProvider(id)
                try {
                    this.manager.terminate(inst)
                } catch (e: Exception) {
                    this.logger(id, "terminate error: ${e.message}")
                }
                this.state.removeInstance(id)
            case None => ()
        }
    }

    /**
     * 崩溃自愈：desired 存在但实际进程已退出 → 重新拉起
     */
    private func healCrashed(): Unit {
        let crashed = ArrayList<String>()
        synchronized(this.state.lock) {
            for ((id, instance) in this.state.actual) {
                if (this.state.desired.contains(id) && this.manager.isExited(instance)) {
                    crashed.add(id)
                }
            }
        }
        for (id in crashed) {
            let entry = this.state.desired.get(id)
            match (entry) {
                case Some(e) =>
                    this.logger(id, "crashed, restarting")
                    this.state.removeInstance(id)
                    this.state.clearServicesByProvider(id)
                    try {
                        this.launchPlugin(e)
                        this.logger(id, "restarted")
                    } catch (ex: Exception) {
                        this.logger(id, "restart failed: ${ex.message}")
                    }
                case None => ()
            }
        }
    }

    /**
     * 拓扑排序：inject 依赖者后启动（简单的依赖分层）
     * 无依赖/依赖已满足的优先；有循环依赖时按原顺序（避免死循环）
     */
    private func topoSort(entries: ArrayList<PluginEntry>): Unit {
        // 构建 serviceKey -> 提供者集合
        let providerOf = HashMap<String, ArrayList<String>>()
        for (entry in entries) {
            for (key in entry.provide) {
                if (!providerOf.contains(key)) {
                    providerOf[key] = ArrayList<String>()
                }
                providerOf[key].add(entry.id)
            }
        }
        let result = ArrayList<PluginEntry>()
        let placed = HashSet<String>()
        var remaining = ArrayList<PluginEntry>(entries)
        var progress = true
        while (progress && remaining.size > 0) {
            progress = false
            let defer = ArrayList<PluginEntry>()
            for (entry in remaining) {
                // 所有依赖都已放置？
                let depsOk = entry.inject.all { key =>
                    if (placed.contains(key) || !providerOf.contains(key)) {
                        true   // 依赖已就绪，或无人提供（等待外部/已存在服务）
                    } else {
                        // 有提供者但尚未放置 → 未就绪
                        providerOf[key].all { pid => placed.contains(pid) }
                    }
                }
                if (depsOk) {
                    result.add(entry)
                    placed.add(entry.id)
                    for (key in entry.provide) {
                        placed.add(key)
                    }
                    progress = true
                } else {
                    defer.add(entry)
                }
            }
            remaining = defer
        }
        // 剩余（循环依赖）按原顺序追加
        for (entry in remaining) {
            result.add(entry)
        }
        entries.clear()
        entries.add(all: result)
    }
}
