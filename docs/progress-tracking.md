# cordis-cj 项目进度跟踪

> 仓颉 Cordis 动态组合框架 —— 「微内核 + 进程隔离」插件框架
> 设计文档：`docs/design.md`（v1.0 草案）、`docs/design-impl.md`（v2.0 实现级）

## 总体计划（P0–P4）

| 阶段 | 内容 | 状态 |
| :--- | :--- | :--- |
| P0 | cordis_core：协议消息类 + 统一配置加载（TOML/JSON） | ✅ 完成 |
| P1 | cordis_host：PipeTransport + PluginManager（进程管理） | ⬜ |
| P2 | cordis_plugin：插件 SDK（PluginRuntime + 服务注册 + invoke 转发） | ⬜ |
| P3 | Reconciler 全量 + 端到端测试 | ⬜ |
| P4 | 宏层 @plugin/@inject/@provide（参考 kux-cj @Crud、CJson @JsonSerializable） | ⬜ |

## 已完成

### P0 — cordis_core（提交 `835d369`，分支 `feat/cordis-core`）

- **`cordis_core/src/methods.cj`**：JSON-RPC 方法名常量（initialize/initialized/provide/dispose/notify/log/invoke/ping/pong）+ NotifyKind/LogLevel 常量。
- **`cordis_core/src/message.cj`**：8 个协议消息类（InitializeParams/Result、ProvideParams/Result、DisposeParams、NotifyParams、LogParams、InvokeParams），全部实现 `JsonSerializable`/`JsonDeserializable<T>`（`stdx.encoding.json.stream` 直通，jsonvalue 仅用于无固定结构的 config/args 字段）。
- **`cordis_core/src/config.cj`**：`PluginEntry`/`CordisConfig` 实现 `Serializable<T>`（`stdx.serialization` DataModel 中间表示）。`ConfigLoader` 提供统一泛型入口：
  - `loadToml<T>(path)` / `parseTomlString<T>(str)` — TOML（`DataModel.fromToml`）
  - `parseJsonString<T>(str)` — JSON（`DataModel.fromJson`）
  - 同一结构 TOML/JSON 双格式读写，无格式耦合。
- **测试**：`cordis_tests` 22 用例全通过（协议往返 16 + 配置 6）。

## 关键决策记录

1. **配置格式**：采用 tomlcj + `Serializable<T>` 统一接口，TOML/JSON 皆可（atelier 同款模式），不绑定具体格式。
2. **宏后置 P4**：运行时库先行；宏可行性已由工作区项目实证（kux-cj @Crud 生成完整服务类、CJson @JsonSerializable 生成序列化代码、defer-cj 重写函数体、embed-cj 宏内执行宿主代码）。
3. **序列化规范**：固定结构类实现 json.stream 接口；jsonvalue 仅用于无固定结构的动态字段（config/args）。

## 工程要点（踩坑记录）

- cjpm workspace 中，源码包声明必须用全限定名：`package ystyle::cordis_core`（`organization::name`）。
- workspace 依赖引用同样用全限定名：`"ystyle::cordis_core" = { path = "../cordis_core" }`。
- test-members 必须是 build-members 的子集。
- `ArrayList` 构造：`ArrayList.of([...])`（Array→ArrayList）；`ArrayList(x)` 是容量构造。
- tomlcj 的 `parse(str).mapping` 的 mapping 非 public，字符串解析应走 `Decoder(ByteBuffer(str.toArray()))`。
- `@Expect` 比较 JsonValue 需要 Equatable（jsonvalue 未实现）→ 用 `match` 断言。
- 泛型交集约束 `T <: A & B<T>` 在 `JsonValue.fromObject/toObject` 处推断困难 → 测试往返直接用 `JsonWriter`/`JsonReader` 直通，不经 jsonvalue。

## 待办 / 下一步

- [ ] P1：PipeTransport（SubProcess 管道 Transport）+ PluginManager（launch/terminate/wait + stderr 转发）
- [ ] P2：cordis_plugin SDK
- [ ] P3：Reconciler + 端到端
