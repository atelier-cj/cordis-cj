package ystyle::cordis_plugin

import jsonvalue.JsonValue
import stdx.encoding.json.stream.{JsonSerializable, JsonDeserializable}
import std.collection.{HashMap, ArrayList, map, collectArray}
import std.sync.Mutex

/**
 * 服务注册表（docs/design-impl.md §6）
 *
 * 管理插件提供的服务（provide/dispose）与可逆效果（disposer 列表）：
 * - register：注册服务，宿主返回 undo_id，凭此可撤销
 * - dispose：按 undo_id 撤销单个服务
 * - effect：注册可逆效果（disposer），卸载时逆序执行（对应 Cordis ctx.effect）
 * - disposeAll：插件卸载时调用，逆序执行全部 disposer 并清空
 */
public class ServiceRegistry {
    // undo_id -> 撤销回调（disposer），按注册顺序维护
    private let services: HashMap<String, () -> Unit> = HashMap<String, () -> Unit>()
    private let serviceOrder: ArrayList<String> = ArrayList<String>()
    // 可逆效果 disposer（无 undo_id），按注册顺序维护
    private let effects: ArrayList<() -> Unit> = ArrayList<() -> Unit>()
    // 服务 Key -> invoke 处理器（宿主转发服务调用时分发）
    private let handlers: HashMap<String, (String, Array<JsonValue>) -> JsonValue> = HashMap<String, (String, Array<JsonValue>) -> JsonValue>()
    private let lock: Mutex = Mutex()

    public init() {}

    /**
     * 注册服务处理器：宿主 invoke 转发到本插件的服务时调用
     * @param key 服务 Key（与 provide 的 Key 对应）
     * @param handler (method, args) -> result
     */
    public func registerHandler(key: String, handler: (String, Array<JsonValue>) -> JsonValue): Unit {
        synchronized(this.lock) {
            this.handlers[key] = handler
        }
    }

    /**
     * 注册服务处理器（泛型版）
     *
     * 参数自动反序列化（T <: JsonDeserializable<T>），返回值自动序列化
     * （R <: JsonSerializable），服务端 handler 直接操作仓颉类型，
     * 省去手动 JsonValue 转换。
     *
     * @param key 服务 Key（与 provide 的 Key 对应）
     * @param handler (method, args: Array<T>) -> R
     */
    public func registerHandler<T, R>(key: String, handler: (String, Array<T>) -> R): Unit
        where T <: JsonDeserializable<T>, R <: JsonSerializable {
        let wrapped: (String, Array<JsonValue>) -> JsonValue = { method, jsonArgs =>
            // JsonValue[] → Array<T>（逐个反序列化）
            let typedArgs = jsonArgs |> map { j => JsonValue.toObject<T>(j) } |> collectArray
            let result = handler(method, typedArgs)
            JsonValue.fromObject(result)
        }
        synchronized(this.lock) {
            this.handlers[key] = wrapped
        }
    }

    /**
     * 分发宿主转发的服务调用
     * @throws Exception 服务不存在时
     */
    public func invokeHandler(service: String, method: String, args: Array<JsonValue>): JsonValue {
        var handler: ?(String, Array<JsonValue>) -> JsonValue = None
        synchronized(this.lock) {
            if (this.handlers.contains(service)) {
                handler = this.handlers[service]
            }
        }
        match (handler) {
            case Some(h) => h(method, args)
            case None => throw Exception("service '${service}' not provided by this plugin")
        }
    }

    /**
     * 注册一个服务，返回宿主下发的 undo_id
     * @param undoId 宿主分配的撤销标识
     */
    public func register(undoId: String): Unit {
        this.register(undoId, { => () })
    }

    /**
     * 注册一个服务，返回宿主下发的 undo_id
     * @param undoId 宿主分配的撤销标识
     * @param disposer 撤销该服务时执行的回调
     */
    public func register(undoId: String, disposer: () -> Unit): Unit {
        synchronized(this.lock) {
            this.services[undoId] = disposer
            this.serviceOrder.add(undoId)
        }
    }

    /**
     * 撤销指定服务（宿主下发 dispose 时调用）
     * @return 是否找到并撤销了该服务
     */
    public func dispose(undoId: String): Bool {
        var disposer: ?() -> Unit = None
        synchronized(this.lock) {
            if (this.services.contains(undoId)) {
                disposer = this.services[undoId]
                this.services.remove(undoId)
                var idx: Int64 = -1
                for (i in 0..this.serviceOrder.size) {
                    if (this.serviceOrder[i] == undoId) {
                        idx = i
                        break
                    }
                }
                if (idx >= 0) {
                    this.serviceOrder.remove(at: idx)
                }
            }
        }
        match (disposer) {
            case Some(f) =>
                f()
                true
            case None => false
        }
    }

    /**
     * 注册可逆效果：返回 disposer，插件卸载时逆序执行（对应 Cordis ctx.effect）
     */
    public func effect(disposer: () -> Unit): Unit {
        synchronized(this.lock) {
            this.effects.add(disposer)
        }
    }

    /**
     * 当前已注册的服务数量
     */
    public prop serviceCount: Int64 {
        get() {
            synchronized(this.lock) {
                this.services.size
            }
        }
    }

    /**
     * 当前已注册的效果数量
     */
    public prop effectCount: Int64 {
        get() {
            synchronized(this.lock) {
                this.effects.size
            }
        }
    }

    /**
     * 卸载全部：逆序执行所有 disposer（效果 + 服务），然后清空
     * 对应 Cordis 卸载时逆序撤销效果（docs/design-impl.md §8）
     */
    public func disposeAll(): Unit {
        let reversedEffects = ArrayList<() -> Unit>()
        let reversedServices = ArrayList<() -> Unit>()
        synchronized(this.lock) {
            // 逆序复制 effects
            for (i in this.effects.size - 1..0) {
                reversedEffects.add(this.effects[i])
            }
            // 逆序复制 services
            for (i in this.serviceOrder.size - 1..0) {
                let undoId = this.serviceOrder[i]
                if (this.services.contains(undoId)) {
                    reversedServices.add(this.services[undoId])
                }
            }
            this.effects.clear()
            this.services.clear()
            this.serviceOrder.clear()
        }
        // 先效果后服务（效果通常先注册，逆序时后执行）
        for (f in reversedEffects) {
            f()
        }
        for (f in reversedServices) {
            f()
        }
    }
}
