# cordis-cj

仓颉（Cangjie）Cordis 动态组合框架 —— 「微内核 + 进程隔离」插件系统。

基于北京大学 & DeepSeek-AI《Revertible Effects and Reactive Coeffects》论文思想，对标 [Cordis](https://github.com/shigma/cordis)（DeepSeek Harness 的插件框架）的语义，用仓颉语言实现：

- **进程隔离**：插件以独立子进程运行，卸载即杀进程，操作系统回收全部资源（规避静态语言无法卸载模块的问题）
- **声明式配置**：TOML 定义期望状态，调和器自动 diff 并执行 Add/Remove/Update
- **服务注入/提供**：插件声明 `inject`/`provide`，宿主按依赖拓扑启动，崩溃自动重启
- **零样板插件开发**：`@Plugin[]` / `@Provide["key"]` 宏自动生成 main、握手与路由注册

## 架构

```
┌─────────────────────────────────────────────────────┐
│                     宿 主 进 程                       │
│  ┌─────────────┐   ┌──────────────────────────────┐  │
│  │  Reconciler │   │  PluginHost                  │  │
│  │  调谐循环    │──▶│  initialize/provide/log 处理器 │  │
│  └─────────────┘   │  serviceIndex / undoMap      │  │
│                    └──────────────┬───────────────┘  │
│                                   │ PipeTransport    │
└───────────────────────────────────┼─────────────────┘
                                    │ stdin/stdout (换行帧 JSON-RPC 2.0)
┌───────────────────────────────────┼─────────────────┐
│                       插件进程 A   ▼                  │
│  ┌──────────────────────────────────────────────┐   │
│  │  PluginRuntime（握手→provide→handler→事件循环）  │   │
│  │  ServiceRegistry（可逆效果/服务撤销）             │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## 模块划分

| 模块 | 包 | 职责 |
|---|---|---|
| `cordis_core` | `ystyle::cordis_core` | 协议消息类（JsonSerializable）、统一 TOML/JSON 配置加载 |
| `cordis_host` | `ystyle::cordis_host` | 进程管理（PipeTransport/PluginManager）、调和器（PluginHost/Reconciler） |
| `cordis_plugin` | `ystyle::cordis_plugin` | 插件 SDK（PluginRuntime/ServiceRegistry）、宏（`ystyle::cordis_plugin.macros`） |

## 快速开始

### 1. 定义插件（普通仓颉类 + 宏，零样板）

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

编译为独立可执行文件（`output-type = "executable"`）：

```toml
[package]
  name = "my_plugin"
  output-type = "executable"
  compile-option = "--static"

[dependencies]
  "ystyle::cordis_plugin" = { path = "../cordis_plugin" }
  "jsonvalue" = "1.1.0"
```

`@Plugin[]` 宏自动生成 `main` + 握手 + 服务注册 + invoke 路由，插件作者完全无感底层 RPC。

> 注意：宏包与调用方需**同模块**（`cordis_plugin.macros` 与插件示例同属 `cordis_plugin` 模块的 CJson 模式）。跨模块消费带 organization 的宏库存在 cjpm 缺陷，详见 [docs/macro-org-dependency-issue.md](docs/macro-org-dependency-issue.md)。

### 2. 编写配置（TOML）

```toml
# cordis.toml
interval = 5          # 调谐周期（秒）
ping_interval = 30    # 探活周期（秒）

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
    let manager = PluginManager()
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

## 不使用宏的插件写法（运行时库显式 API）

```cangjie
import ystyle::cordis_plugin.*

main(): Int64 {
    PluginRuntime.run("my-plugin", [], ["echo"], { ctx =>
        ctx.registerHandler("echo", { method, args =>
            if (args.size > 0) { args[0] } else { JsonValue.Null }
        })
        ctx.log("info", "plugin ready")
    })
    return 0
}
```

`PluginContext` 提供：`provide` / `dispose` / `registerHandler` / `effect`（可逆效果）/ `invoke` / `log`。

## 协议

- **传输**：插件 stdin/stdout 管道，换行分隔帧（`NewlineFraming`）
- **消息**：JSON-RPC 2.0
- **方法**：`initialize` / `initialized` / `provide` / `dispose` / `notify` / `log` / `invoke` / `ping`

> 设计初稿为 Content-Length 帧（LSP 风格），因仓颉 `ConsoleReader.read(Array<Byte>)` 在管道 stdin 下永久阻塞而改用换行帧（与 mcp-cj 生产方案一致），详见 [docs/progress-tracking.md](docs/progress-tracking.md)。

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

38 个用例，覆盖：协议序列化往返、配置解析、管道传输（真实子进程）、进程管理、插件运行时（内存双端对接）、端到端（真实宿主 ↔ 真实插件进程：握手/服务注册/invoke/热卸载/崩溃自愈）、宏插件生命周期。

## 文档

- [设计文档（v1.0 草案）](docs/design.md)
- [实现级设计文档（v2.0，真实 API）](docs/design-impl.md)
- [进度跟踪与踩坑记录](docs/progress-tracking.md)
- [cjpm 宏包 organization 缺陷排查](docs/macro-org-dependency-issue.md)

## License

MIT
