# Cordis 事件总线 —— 设计文档（v1.0）

**文档状态**：实现前设计稿
**关联**：`docs/design-impl.md` §4（协议）、`docs/progress-tracking.md`（进度）
**目标**：为 cordis-cj 增加插件间**解耦事件通信**，对齐 Cordis `ctx.on/emit/waterfall/parallel/serial` 语义（参考 dsh 的 `docs/cordis-api/events.md` 与 `docs/cordis-tutorial/04-events.md`）。

---

## 1. 设计目标

1. **解耦**：插件 A 发布事件不关心谁在听；插件 B 订阅事件不需要知道 A 是谁（与现有"服务调用"点对点语义互补）。
2. **复用现有链路**：事件经宿主路由（插件 → 宿主 → 订阅者），复用换行帧 JSON-RPC、PluginHost、PipeTransport，不引入新传输。
3. **对齐 Cordis 派发模式**：`emit`（同步广播）为 v1 核心，`waterfall`/`parallel`/`serial` 作为 v2 增强（见 §7）。
4. **生命周期绑定**：订阅是"效果"（effect）——插件卸载时自动取消订阅（对齐 Cordis `ctx.on` 语义）。

## 2. 术语

| 术语 | 含义 |
| :--- | :--- |
| 事件名（event name） | 全局唯一的字符串标识，如 `"stats/report"`、`"agent/request"` |
| 发布者（publisher） | 调用 `ctx.emit` 的插件 |
| 订阅者（subscriber） | 调用 `ctx.on` 的插件 |
| 派发模式（dispatch mode） | 事件的分发策略（emit/waterfall/parallel/serial） |

## 3. 总体流程

```
插件 A（发布者）                     宿 主                      插件 B / C（订阅者）
     │  ctx.emit("stats/report", n)   │                            │
     │ ──────────────RPC────────────▶ │  EventRegistry 查订阅者     │
     │                                │ ────── dispatch ─────────▶ │ B.on(...) 执行
     │                                │ ────── dispatch ─────────▶ │ C.on(...) 执行
     │                                │ ◀────────── 结果/无 ────── │
     │ ◀──────── 汇总（可选）───────── │                            │
```

- 事件参数：`Array<JsonValue>`（复用现有动态值处理，无固定结构 → jsonvalue 合法使用）。
- 订阅注册：插件启动时 `ctx.on` → 宿主 `EventRegistry` 记录（插件 id, 事件名, 回调）。

## 4. 协议扩展（JSON-RPC 2.0，换行帧）

### 4.1 方法名（新增至 `cordis_core/src/methods.cj`）

| 方法 | 方向 | 类型 | 说明 |
| :--- | :--- | :--- | :--- |
| `events/subscribe` | 插件 → 宿主 | 请求（返回订阅 id） | 订阅事件 |
| `events/unsubscribe` | 插件 → 宿主 | 请求 | 取消订阅（插件卸载时） |
| `events/dispatch` | 宿主 → 插件 | 请求（返回处理结果） | 向单个订阅者派发事件 |
| `events/emit` | 插件 → 宿主 | 通知 | 发布事件（宿主负责扇出） |

> 订阅/退订用**请求**（需确认）；派发用**请求**（emit 模式需等订阅者处理完，保证"同步广播"语义）；发布用**通知**（发布者不等待，宿主异步扇出）。
> 说明：`emit` 在 Cordis 中是"同步广播、不等结果"，但跨进程场景发布者的"不等待"是用户感知——内部宿主仍需同步等订阅者处理完，保证订阅者侧的顺序性。v1 按"宿主同步派发"实现。

### 4.2 消息类（新增至 `cordis_core/src/message.cj`，全部实现 JsonSerializable/JsonDeserializable）

```cangjie
// events/subscribe.params
public class SubscribeParams <: JsonSerializable & JsonDeserializable<SubscribeParams> {
    public let event: String      // 事件名
}

// events/subscribe 响应 result
public class SubscribeResult <: JsonSerializable & JsonDeserializable<SubscribeResult> {
    public let subscriptionId: String   // 订阅 id（退订用）
}

// events/unsubscribe.params
public class UnsubscribeParams <: JsonSerializable & JsonDeserializable<UnsubscribeParams> {
    public let subscriptionId: String
}

// events/emit.params（通知）
public class EmitParams <: JsonSerializable & JsonDeserializable<EmitParams> {
    public let event: String
    public let args: Array<JsonValue>
}

// events/dispatch.params（宿主 → 订阅者）
public class DispatchParams <: JsonSerializable & JsonDeserializable<DispatchParams> {
    public let event: String
    public let args: Array<JsonValue>
    public let emitId: String      // 一次 emit 的唯一标识（v2 聚合结果用，v1 仅透传）
}
```

## 5. 宿主侧：EventRegistry

### 5.1 结构（新增 `cordis_host/src/event_registry.cj`）

```cangjie
public class EventRegistry {
    // 事件名 -> 订阅者列表（有序，保持注册顺序）
    private let subscribers: HashMap<String, ArrayList<Subscription>>
    // subscriptionId -> Subscription（退订用）
    private let byId: HashMap<String, Subscription>
    private let lock: Mutex = Mutex()

    public class Subscription {
        public let id: String
        public let pluginId: String
        public let event: String
        public let instance: PluginInstance   // 派发目标连接
    }
}
```

### 5.2 API

| 方法 | 说明 |
| :--- | :--- |
| `subscribe(event, pluginId, instance): String` | 注册订阅，分配 subscriptionId |
| `unsubscribe(subscriptionId): Bool` | 取消订阅 |
| `unsubscribeAll(pluginId): Unit` | 插件卸载时清理其全部订阅 |
| `dispatch(event, args, emitId): Unit` | 向该事件所有订阅者派发（遍历调用 instance.client 的 `events/dispatch`） |

### 5.3 接入 PluginHost

- `PluginHost` 增加 `eventRegistry: EventRegistry`。
- `registerHostHandlers` 中注册：
  - `events/subscribe` 请求处理器 → `eventRegistry.subscribe` + 返回 subscriptionId
  - `events/unsubscribe` 请求处理器 → `eventRegistry.unsubscribe`
  - `events/emit` 通知回调 → 查订阅者 → 逐个 `dispatch`（同步遍历）
- `removePlugin` 中调用 `eventRegistry.unsubscribeAll(pluginId)`（生命周期绑定）。

## 6. 插件侧 API（`PluginContext` 扩展）

```cangjie
/**
 * 订阅事件：插件卸载时自动取消订阅（效果语义）
 * @param event 事件名
 * @param listener 回调（参数列表）
 * @return 订阅 id
 */
public func on(event: String, listener: (Array<JsonValue>) -> Unit): String {
    // 1. 向宿主发 events/subscribe 请求 → subscriptionId
    // 2. 在 ServiceRegistry 注册 effect：卸载时发 events/unsubscribe
    // 3. 注册本地处理器：宿主 events/dispatch 到达时调用 listener
}

/**
 * 发布事件：不等待订阅者
 * @param event 事件名
 * @param args 参数列表
 */
public func emit(event: String, args: Array<JsonValue>): Unit {
    // 向宿主发 events/emit 通知
}
```

**插件侧实现要点**：
- `ctx.on` 需要注册一个**本地 dispatch 处理器**（`server.register("events/dispatch", ...)`），宿主派发到来时解析 `DispatchParams` 调 listener。
- 退订走 effect：`ctx.effect { => unsubscribe(subscriptionId) }`（对齐 Cordis `ctx.on` 卸载自动移除）。
- 事件参数是动态结构 → jsonvalue `Array<JsonValue>`（符合 AGENTS.md"实在没固定结构可用 jsonvalue"）。

## 7. 派发模式（分层）

| 版本 | 模式 | 语义 | 实现 |
| :--- | :--- | :--- | :--- |
| **v1** | `emit` | 同步广播：宿主按注册顺序逐个派发，不等返回值 | 宿主遍历 `subscribers[event]`，逐连接发 `events/dispatch`（同步等待响应） |
| v2 | `waterfall` | 中间件链：订阅者可改写/短路（`next` 语义） | dispatch 参数带 `next` 标志，宿主按序传递返回值 |
| v2 | `parallel` | 并发派发 | 宿主并发发 `events/dispatch` 后聚合 |
| v2 | `serial` | 按序直到订阅者"表态" | 宿主逐发，遇非空返回值停止 |

> v1 只做 `emit`：事件参数 `Array<JsonValue>`、宿主同步按序派发、无返回值聚合。waterfall/parallel/serial 需要"返回值跨进程回传 + 顺序/并发控制"，复杂度高，列入 v2。

## 8. 错误处理与边界

- **订阅者进程已退出**：派发时 `client.call` 超时/EOF → 跳过该订阅者并自动 `unsubscribe`（崩溃清理）。
- **事件无订阅者**：`emit` 静默成功（发布者不感知）。
- **重复订阅**：同一插件对同一事件多次 `on` 允许（各自独立订阅 id）。
- **卸载清理**：`removePlugin` → `unsubscribeAll`（防幽灵订阅）。
- **参数序列化失败**：emit 参数为 JsonValue 数组，宿主直接透传，不反序列化（减少出错面）。

## 9. 测试计划

| 测试 | 覆盖 |
| :--- | :--- |
| `SubscribeParams/Result/EmitParams/DispatchParams` 序列化往返 | 消息类（cordis_core） |
| `EventRegistryTest` | 订阅/退订/按插件清理/dispatch 遍历（MemoryDuplexTransport 模拟） |
| `EventRegistryTest` 无订阅者/重复订阅 | 边界 |
| `PluginContextTest.testOnEmit` | 插件侧 on/emit 全链路（FakeHost） |
| `EndToEndTest.testEventBus` | **真实双插件进程**：插件 A emit → 宿主路由 → 插件 B 收到并响应 |
| `EndToEndTest.testEventCleanupOnUnload` | 插件卸载后订阅自动清理 |

## 10. 实施步骤（P6-Events）

1. **P6.1**：cordis_core 消息类 + 方法常量 + 单测。
2. **P6.2**：cordis_host EventRegistry + PluginHost 接入 + 单测（MemoryDuplexTransport）。
3. **P6.3**：cordis_plugin `ctx.on`/`ctx.emit` + 单测（FakeHost）。
4. **P6.4**：端到端（真实双插件进程 emit → 订阅者收到；卸载清理）。
5. 每步遵循 TDD：先写用例 → 实现 → `cjpm test` 通过 → 提交。

## 11. 不做的事（v1 范围外）

- waterfall / parallel / serial 派发模式（v2）。
- 事件参数类型安全（保持 `Array<JsonValue>`；后续可参考服务调用的 `invoke<T,R>` 泛型化思路做 `on<T>` 重载）。
- 跨宿主的分布式事件（单宿主内路由）。
- 事件持久化/重放。
