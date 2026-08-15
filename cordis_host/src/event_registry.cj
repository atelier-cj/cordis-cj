package ystyle::cordis_host

import ystyle::cordis_core.{Methods, EmitParams, DispatchParams}
import ystyle::jsonrpc.JsonRpcClient
import jsonvalue.JsonValue
import std.collection.{HashMap, ArrayList}
import std.sync.Mutex

/**
 * 事件订阅记录（docs/design-events.md §5.1）
 */
public class Subscription {
    public let id: String
    public let pluginId: String
    public let event: String
    public let instance: PluginInstance

    public init(id: String, pluginId: String, event: String, instance: PluginInstance) {
        this.id = id
        this.pluginId = pluginId
        this.event = event
        this.instance = instance
    }
}

/**
 * 事件注册表（docs/design-events.md §5）
 *
 * 管理插件的事件订阅与派发：
 * - subscribe：插件订阅事件，分配 subscriptionId
 * - unsubscribe：取消订阅
 * - unsubscribeAll：插件卸载时清理其全部订阅
 * - dispatch：向事件所有订阅者派发（同步按注册顺序，调订阅者连接 events/dispatch）
 */
public class EventRegistry {
    // 事件名 -> 订阅者列表（有序，保持注册顺序）
    private let subscribers: HashMap<String, ArrayList<Subscription>> = HashMap<String, ArrayList<Subscription>>()
    // subscriptionId -> Subscription（退订用）
    private let byId: HashMap<String, Subscription> = HashMap<String, Subscription>()
    private let lock: Mutex = Mutex()
    private var idCounter: Int64 = 0

    public init() {}

    /**
     * 订阅事件
     * @param event 事件名
     * @param pluginId 订阅者插件 id
     * @param instance 订阅者实例（派发目标连接）
     * @return 订阅 id
     */
    public func subscribe(event: String, pluginId: String, instance: PluginInstance): String {
        let id = this.allocateId()
        let sub = Subscription(id, pluginId, event, instance)
        synchronized(this.lock) {
            if (!this.subscribers.contains(event)) {
                this.subscribers[event] = ArrayList<Subscription>()
            }
            this.subscribers[event].add(sub)
            this.byId[id] = sub
        }
        id
    }

    /**
     * 取消订阅
     * @return 是否找到并取消了该订阅
     */
    public func unsubscribe(subscriptionId: String): Bool {
        synchronized(this.lock) {
            if (this.byId.contains(subscriptionId)) {
                let sub = this.byId[subscriptionId]
                this.byId.remove(subscriptionId)
                if (this.subscribers.contains(sub.event)) {
                    let list = this.subscribers[sub.event]
                    var idx: Int64 = -1
                    for (i in 0..list.size) {
                        if (list[i].id == subscriptionId) {
                            idx = i
                            break
                        }
                    }
                    if (idx >= 0) {
                        list.remove(at: idx)
                    }
                    if (list.size == 0) {
                        this.subscribers.remove(sub.event)
                    }
                }
                true
            } else {
                false
            }
        }
    }

    /**
     * 插件卸载时清理其全部订阅
     */
    public func unsubscribeAll(pluginId: String): Unit {
        synchronized(this.lock) {
            let staleIds = ArrayList<String>()
            for ((id, sub) in this.byId) {
                if (sub.pluginId == pluginId) {
                    staleIds.add(id)
                }
            }
            for (id in staleIds) {
                let sub = this.byId[id]
                this.byId.remove(id)
                if (this.subscribers.contains(sub.event)) {
                    let list = this.subscribers[sub.event]
                    var idx: Int64 = -1
                    for (i in 0..list.size) {
                        if (list[i].id == id) {
                            idx = i
                            break
                        }
                    }
                    if (idx >= 0) {
                        list.remove(at: idx)
                    }
                    if (list.size == 0) {
                        this.subscribers.remove(sub.event)
                    }
                }
            }
        }
    }

    /**
     * 某事件的订阅者数量（测试/诊断用）
     */
    public func subscriberCount(event: String): Int64 {
        synchronized(this.lock) {
            if (this.subscribers.contains(event)) {
                this.subscribers[event].size
            } else {
                0
            }
        }
    }

    /**
     * 向事件的所有订阅者派发（同步按注册顺序）
     * @param emitId 本次 emit 的唯一标识
     * @return 成功派发的订阅者数量（跳过崩溃/超时的订阅者）
     */
    public func dispatch(event: String, args: Array<JsonValue>, emitId: String): Int64 {
        let targets = synchronized(this.lock) {
            if (this.subscribers.contains(event)) {
                ArrayList<Subscription>(this.subscribers[event])
            } else {
                ArrayList<Subscription>()
            }
        }
        var delivered: Int64 = 0
        for (sub in targets) {
            try {
                let params = DispatchParams(event, args, emitId)
                let result = sub.instance.client.call<JsonValue, JsonValue>(
                    Methods.EVENTS_DISPATCH,
                    params: Some(JsonValue.fromObject(params)),
                    timeout: 10 * Duration.second)
                match (result) {
                    case Ok(_) => delivered++
                    case Err(e) =>
                        // 派发失败（订阅者超时/崩溃）→ 跳过并自动清理
                        this.unsubscribe(sub.id)
                }
            } catch (e: Exception) {
                this.unsubscribe(sub.id)
            }
        }
        delivered
    }

    /**
     * 从 emit 通知解析并派发（PluginHost 的 events/emit 回调调用）
     */
    public func dispatchEmit(emitParams: EmitParams, emitId: String): Int64 {
        this.dispatch(emitParams.event, emitParams.args, emitId)
    }

    private func allocateId(): String {
        synchronized(this.lock) {
            this.idCounter++
            "sub-${this.idCounter}"
        }
    }
}
