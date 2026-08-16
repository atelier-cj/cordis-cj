# cordis-cj

仓颉（Cangjie）Cordis 动态组合框架 —— 「微内核 + 进程隔离」插件系统。

基于北京大学 & DeepSeek-AI《Revertible Effects and Reactive Coeffects》论文思想，对标 [Cordis](https://github.com/shigma/cordis)（DeepSeek Harness 的插件框架）的语义，用仓颉语言实现：

- **进程隔离**：插件以独立子进程运行，卸载即杀进程，操作系统回收全部资源（规避静态语言无法卸载模块的问题）
- **双传输模式**：stdio（管道，默认）或 UDS（Unix Domain Socket），由服务参数 `transport` 全局切换
- **声明式配置**：TOML/JSON 定义期望状态，调和器自动 diff 并执行 Add/Remove/Update
- **服务注入/提供**：插件声明 `inject`/`provide`，宿主按依赖拓扑启动，崩溃自动重启
- **零样板插件开发**：`@Plugin[]` / `@Provide["key"]` / `@Inject["key"]` 宏自动生成 main、握手与路由注册
- **事件总线**：`ctx.on` / `ctx.emit` 解耦插件间通信，宿主扇出路由
- **类型安全**：`invoke<T, R>` / `registerHandler<T, R>` 泛型 API 自动序列化/反序列化

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│                       宿 主 进 程                             │
│  ┌─────────────┐   ┌─────────────────────────────────────┐  │
│  │  Reconciler │   │  PluginHost                         │  │
│  │  调谐循环    │──▶│  initialize/provide/log 处理器       │  │
│  └─────────────┘   │  serviceIndex / undoMap / 事件注册表   │  │
│                    └──────────────┬──────────────────────┘  │
└───────────────────────────────────┼─────────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │ stdio：stdin/stdout 管道    │ uds：Unix Domain Socket     │
        │ NewlineFraming             │ ContentLengthFraming       │
        │ PipeTransport (宿主)        │ UnixServerTransport (宿主)  │
        │ LineStdioTransport (插件)   │ UnixClientTransport (插件)  │
        ▼                            ▼
┌────────────────────────────┐  ┌────────────────────────────┐
│              插件进程 A      │  │              插件进程 B      │
│  PluginRuntime             │  │  PluginRuntime             │
│  握手 → provide → handler   │  │  握手 → provide → handler   │
│  ServiceRegistry（可逆效果） │  │  ServiceRegistry（可逆效果） │
└────────────────────────────┘  └────────────────────────────┘
```

## 模块划分

| 模块 | 包 | 职责 |
|---|---|---|
| `cordis_core` | `ystyle::cordis_core` | 协议消息类（JsonSerializable）、统一 TOML/JSON 配置加载 |
| `cordis_host` | `ystyle::cordis_host` | 进程管理（PipeTransport/UnixServerTransport/PluginManager）、调和器（PluginHost/Reconciler） |
| `cordis_plugin` | `ystyle::cordis_plugin` | 插件 SDK（PluginRuntime/ServiceRegistry）、宏（`ystyle::cordis_plugin.macros`） |

## 快速开始

### 1. 定义插件（两种写法二选一）

#### 写法 A：宏（零样板，推荐框架内置插件）

`@Plugin[]` 宏自动生成 `main` + 握手 + 服务注册 + invoke 路由；`@Provide["key"]` 声明提供服务；`@Inject["key"]` 声明依赖注入（自动生成 `ServiceProxy`）。

```cangjie
// my_plugin/src/main.cj
import ystyle::cordis_plugin.macros.*
import jsonvalue.*

@Plugin[]
public class MyPlugin {
    @Provide["echo"]
    public func echo(args: Array<JsonValue>): JsonValue {
        if (args.size > 0) { args[0] } else { JsonValue.Null }
    }

    @Provide["add"]
    public func add(args: Array<JsonValue>): JsonValue {
        let a = match (args[0]) { case JsonValue.Number(n) => n; case _ => 0.0 }
        let b = match (args[1]) { case JsonValue.Number(n) => n; case _ => 0.0 }
        JsonValue.Number(a + b)
    }
}
```

> 注意：宏包与调用方需**同模块**（`cordis_plugin.macros` 与插件示例同属 `cordis_plugin` 模块的 CJson 模式）。跨模块消费带 organization 的宏库存在 cjpm 缺陷，详见 [docs/macro-org-dependency-issue.md](docs/macro-org-dependency-issue.md)。

#### 写法 B：显式 API（推荐外部插件作者）

手写 `main` + `PluginRuntime.run`，不依赖宏，不受宏跨模块缺陷影响。**同一份代码可同时支持 stdio 与 UDS 两种传输**：用 `parseUdsArg(args)` 检测宿主传入的 `--uds <path>` 参数，有则走 UDS，否则走 stdio。

```cangjie
// my_plugin/src/main.cj（独立模块）
import ystyle::cordis_plugin.*
import jsonvalue.*

main(args: Array<String>): Int64 {
    let handler = { ctx: PluginContext =>
        ctx.registerHandler("echo", { method, args =>
            if (args.size > 0) { args[0] } else { JsonValue.Null }
        })
        ctx.log("info", "plugin ready")
    }
    // 宿主按 transport 配置传入 --uds 参数；无则默认 stdio
    match (PluginRuntime.parseUdsArg(args)) {
        case Some(path) => PluginRuntime.runUds(path, "my-plugin", [], ["echo"], handler)
        case None       => PluginRuntime.run("my-plugin", [], ["echo"], handler)
    }
    return 0
}
```

编译为独立可执行文件（两种写法相同配置）：

```toml
[package]
  name = "my_plugin"
  output-type = "executable"
  compile-option = "--static"

[dependencies]
  "ystyle::cordis_plugin" = { path = "../cordis_plugin" }   # 带 org 的普通库跨模块依赖正常
  "jsonvalue" = "1.1.0"
```

### 2. 编写配置（TOML）

```toml
# cordis.toml
interval = 5          # 调谐周期（秒）
ping_interval = 30    # 探活周期（秒）
transport = "stdio"   # 传输模式："stdio"（管道，默认）| "uds"（Unix Domain Socket）
uds_path = ""         # UDS 模式下的监听 socket 路径（如 "/tmp/cordis.sock"）

[[plugins]]
id = "my-plugin"
source = "./target/release/bin/my_plugin"
provide = ["echo", "add"]
enabled = true

[plugins.config]
# 插件私有配置（透传）
```

### 3. 宿主加载

```cangjie
import ystyle::cordis_host.*

main() {
    let cfg = ConfigLoader.load("cordis.toml")
    // 按服务参数选择传输模式：uds → PluginManager(uds_path)；默认 stdio → PluginManager()
    let manager = if (cfg.transport == "uds") {
        PluginManager(cfg.udsPath)
    } else {
        PluginManager()
    }
    let host = PluginHost(manager)
    // 启动调谐循环（spawn 后台线程，每 interval 秒一轮）
    spawn {
        while (true) {
            host.reconcile("cordis.toml")
            sleep(5 * Duration.second)
        }
    }
    // 阻塞主进程
    while (true) { sleep(Duration.hour) }
}
```

宿主会自动：拉起插件 → 握手 → 依赖拓扑排序 → 崩溃自愈重启 → 配置变更热调整。

### 4. 服务调用（invoke 转发）

宿主侧通过插件连接的 RPC 调用其服务：

```cangjie
// 向插件实例发起 invoke
let result = instance.client.call<JsonValue, JsonValue>("invoke",
    params: Some(JsonValue.fromObject(InvokeParams("add", "add",
        [JsonValue.Number(2.0), JsonValue.Number(3.0)]))))
// result == Ok(JsonValue.Number(5.0))
```

插件侧经宿主转发调用其他插件的服务（`ctx.invoke`），或通过 `@Inject` 注入的 `ServiceProxy`：

```cangjie
// 写法 A：显式调用
let sum = ctx.invoke<AddRequest, Int64>("calc", "add", [AddRequest(2, 3)])

// 写法 B：@Inject 注入的代理（宏生成，自动注入依赖）
@Inject["add"]
public var add: ServiceProxy
// this.add.call<JsonValue>("add", [JsonValue.Number(5.0), JsonValue.Number(6.0)])
```

## 传输模式：stdio 与 UDS

由 `CordisConfig.transport` 服务参数切换，**插件代码零感知**（`PluginRuntime.run` / `runUds` 自动选择，宿主自动传递 `--uds` 参数）：

| 维度 | stdio（默认） | UDS |
| :--- | :--- | :--- |
| 宿主传输层 | `PipeTransport`（子进程管道） | `UnixServerTransport`（bind + accept） |
| 插件传输层 | `LineStdioTransport`（readln 逐行） | `UnixClientTransport`（connect） |
| 帧协议 | `NewlineFraming`（管道 read 阻塞坑） | `ContentLengthFraming`（标准） |
| 插件侧入口 | `PluginRuntime.run(...)` | `PluginRuntime.runUds(path, ...)` |
| 平台 | 全平台 | Linux/macOS（std.net 不支持 Windows） |
| 崩溃检测 | stdout EOF | socket EOF（语义一致，自愈逻辑共用） |

> **为什么帧协议不同**：仓颉 `ConsoleReader.read(Array<Byte>)` 在管道 stdin 下永久阻塞，stdio 只能用 `readln()` + 换行帧；UDS 的 `read` 是标准流式读（EOF 返回 -1/0），可用 jsonrpc 默认的 Content-Length 帧（与 MCP 等标准一致）。详见 [docs/design-impl.md §3.4](docs/design-impl.md)。

## 泛型类型安全 API（推荐）

`registerHandler<T, R>` 与 `invoke<T, R>` 自动完成序列化/反序列化，业务代码直接操作仓颉类型（基础类型或自定义 DTO），省去手动 JsonValue 转换：

```cangjie
// 自定义 DTO（实现 json.stream 的 JsonSerializable / JsonDeserializable 接口）
public class AddRequest <: JsonSerializable & JsonDeserializable<AddRequest> {
    public let a: Int64
    public let b: Int64
    public init(a: Int64, b: Int64) { this.a = a; this.b = b }
    public func toJson(w: JsonWriter): Unit { /* ... */ }
    public static func fromJson(r: JsonReader): AddRequest { /* ... */ }
}

main(): Int64 {
    PluginRuntime.run("my-plugin", [], ["calc"], { ctx =>
        // 服务端：参数 Array<AddRequest> 自动反序列化，返回 Int64 自动序列化
        ctx.registerHandler<AddRequest, Int64>("calc", { method, args =>
            args[0].a + args[0].b
        })
    })
    return 0
}
```

`PluginContext` 提供：`provide` / `dispose` / `registerHandler`（含泛型版）/ `effect`（可逆效果）/ `invoke`（含泛型版）/ `log` / `on` / `emit` / `proxy`。

## 事件总线

插件间解耦通信：任意插件 `emit` 事件，宿主扇出给所有 `on` 订阅者（发布者不等待、不感知订阅者）：

```cangjie
// 订阅者：收到 stats/report 事件时回调（订阅是效果，卸载自动退订）
ctx.on("stats/report", { args => ctx.log("info", "received: ${args[0]}") })

// 发布者：通知宿主扇出（不等待订阅者）
ctx.emit("stats/report", [JsonValue.Number(1.0)])
```

## 协议

- **传输**：stdio（换行帧）或 UDS（Content-Length 帧），由 `transport` 服务参数切换
- **消息**：JSON-RPC 2.0
- **方法**：`initialize` / `initialized` / `provide` / `dispose` / `notify` / `log` / `invoke` / `ping` / `events/subscribe|unsubscribe|emit|dispatch`

## 配置加载（统一 TOML/JSON）

`ConfigLoader` 基于 `Serializable<T>` + DataModel 中间表示，同一结构可读写 TOML 或 JSON：

```cangjie
let cfg = ConfigLoader.parseString<CordisConfig>(tomlStr)   // TOML
let cfg = ConfigLoader.parseJsonString<CordisConfig>(jsonStr)  // JSON
let cfg = ConfigLoader.load("cordis.toml")                  // 文件
```

## 测试

```shell
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm test -j 16 --no-progress
```

72 个用例，覆盖：协议序列化往返、配置解析（含 UDS 服务参数）、管道传输（真实子进程）、UDS 传输回环、进程管理、插件运行时（内存双端对接）、端到端（stdio + UDS 双模式真实宿主 ↔ 真实插件进程：握手/服务注册/invoke/热卸载/崩溃自愈）、宏插件生命周期、独立模块外部插件生命周期、泛型 invoke/registerHandler 全链路、事件总线。

## 文档

- [设计文档（v1.0 草案）](docs/design.md)
- [实现级设计文档（v2.0，真实 API）](docs/design-impl.md)
- [进度跟踪与踩坑记录](docs/progress-tracking.md)
- [cjpm 宏包 organization 缺陷排查](docs/macro-org-dependency-issue.md)

## License

MIT
