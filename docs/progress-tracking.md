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

### P1 — cordis_host（提交 `c4a1e1e`，分支 `feat/cordis-host`）

- **`cordis_core/src/status.cj`**：`InstanceStatus` 枚举（Starting/Active/Unloading/Failed/Unreachable），`@Derive[Equatable]`。
- **`cordis_host/src/pipe_transport.cj`**：`PipeTransport` 实现 jsonrpc `Transport` 接口——`send` 写子进程 stdin、`receive` 读子进程 stdout（EOF 返回 None，JsonRpcClient 自动停止 = 崩溃检测信号源）、`close` 置标志（OutputStream 无 close()，EOF 通知由 terminate 强杀完成）。
- **`cordis_host/src/plugin_instance.cj`**：`PluginInstance`（entry + SubProcess + JsonRpcClient + status + provides 表）。
- **`cordis_host/src/plugin_manager.cj`**：`PluginManager`——`launch`（三流 Pipe + 建连 + stderr 转发线程）、`terminate`（关连接 + 强杀 + wait 回收防僵尸）、`isExited`（client.isClosed 探测崩溃）、`forwardStderr`（StringReader 逐行转发）。
- **测试**：新增 PipeTransport 5 用例（cat 回显/close/EOF/大消息 5000 字节）+ PluginManager 3 用例（生命周期/stderr 转发/进程退出探测），共 30 用例全通过（含真实子进程）。

### P2 — cordis_plugin（提交 `76f30ae`，分支 `feat/cordis-plugin`）

- **`cordis_plugin/src/service_registry.cj`**：`ServiceRegistry`——服务注册/撤销（undo_id → disposer）+ 可逆效果列表（effect，卸载逆序执行）+ 服务处理器注册与 invoke 分发（`invokeHandler(service, method, args)`）。
- **`cordis_plugin/src/plugin_runtime.cj`**：`PluginContext`（provide/dispose/registerHandler/effect/invoke/log）+ `PluginRuntime.run(pluginId, inject, provide, handler)`——握手（initialize 请求）→ 注册服务（provide 请求拿 undo_id）→ 业务 handler → 阻塞等连接关闭 → 逆序 disposeAll。宿主 → 插件处理器：initialized/dispose/notify/ping/invoke。
- **测试基础设施**：`MemoryDuplexTransport`（内存双工管道，两端点共享单向管道）——无需真实子进程即可对接宿主 JsonRpcClient 与插件 JsonRpcServer。
- **测试**：`FakeHost`（模拟宿主）验证完整流程：握手 + 双服务 provide、invoke 转发（calc.add = 2+3 → 5）、dispose 撤销、ping 探活。共 34 用例全通过。
- **关键**：插件侧用 `JsonRpcServer.start()`（后台 receiveLoop）+ `request()`（主动请求宿主），不能 start()+serve() 双 receiveLoop；阻塞等待用轮询 `server.isClosed()`。

### P3 — Reconciler + 端到端（提交中，分支 `feat/cordis-reconciler`）

- **`cordis_host/src/host_state.cj`**：`HostState`——desired/actual/serviceIndex/undoMap，服务注册/撤销/按提供者清理。
- **`cordis_host/src/plugin_host.cj`**：`PluginHost`——宿主侧 RPC 处理器（initialize 依赖检查 + provide 分配 undo_id + log 收集）、`launchPlugin`、`reconcile`（读 TOML → diff → 拓扑排序 → 先加后删 → 崩溃自愈 `healCrashed`）、`removePlugin`（终止 + 清理服务注册表）。
- **`cordis_plugin/src/line_stdio_transport.cj`**：`LineStdioTransport`——插件侧换行帧传输（readln 逐行 + 补回 \n）。
- **`cordis_plugin/src/examples/e2e/main.cj`**：端到端测试插件（echo/add 两服务），静态编译为独立可执行。
- **测试**：`EndToEndTest` 3 用例（真实宿主 + 真实插件进程）：完整生命周期（握手→服务注册→invoke 2+3=5→echo→热卸载清理）、配置调谐（TOML 拉起插件）、崩溃自愈（强杀后自动重启）。**共 37 用例全通过**。

## 关键决策记录

1. **配置格式**：采用 tomlcj + `Serializable<T>` 统一接口，TOML/JSON 皆可（atelier 同款模式），不绑定具体格式。
2. **宏后置 P4**：运行时库先行；宏可行性已由工作区项目实证（kux-cj @Crud 生成完整服务类、CJson @JsonSerializable 生成序列化代码、defer-cj 重写函数体、embed-cj 宏内执行宿主代码）。
3. **序列化规范**：固定结构类实现 json.stream 接口；jsonvalue 仅用于无固定结构的动态字段（config/args）。
4. **jsonrpc 依赖**：中心仓 jsonrpc 0.4.2 无配套 jsonrpc_stdio（0.4.1 未发布）→ 全部改用本地 path 依赖 `../../json-rpc/jsonrpc`（版本一致、stdio 可用）。
5. **帧协议改为换行帧（重要修正）**：仓颉 `ConsoleReader.read(Array<Byte>)` 在管道 stdin（子进程被 launch 拉起的场景）下永久阻塞，无法用于 Content-Length 帧；`readln()` 可靠。→ 插件侧 `LineStdioTransport`（readln 逐行 + 补回 `\n`）+ `NewlineFraming`，宿主侧 PipeTransport 同步 `NewlineFraming`（与 mcp-cj 生产方案一致）。设计文档 §4 的 Content-Length 帧在此环境不可行，已修正。

## 工程要点（踩坑记录）

- cjpm workspace 中，源码包声明必须用全限定名：`package ystyle::cordis_core`（`organization::name`）。
- workspace 依赖引用同样用全限定名：`"ystyle::cordis_core" = { path = "../cordis_core" }`。
- test-members 必须是 build-members 的子集。
- `ArrayList` 构造：`ArrayList.of([...])`（Array→ArrayList）；`ArrayList(x)` 是容量构造。
- tomlcj 的 `parse(str).mapping` 的 mapping 非 public，字符串解析应走 `Decoder(ByteBuffer(str.toArray()))`。
- `@Expect` 比较 JsonValue 需要 Equatable（jsonvalue 未实现）→ 用 `match` 断言。
- 泛型交集约束 `T <: A & B<T>` 在 `JsonValue.fromObject/toObject` 处推断困难 → 测试往返直接用 `JsonWriter`/`JsonReader` 直通，不经 jsonvalue。
- `OutputStream` 无 `close()` 接口 → PipeTransport.close 只置标志，通知插件 EOF 由 terminate 强杀完成（stdout 关闭 → 宿主 receive EOF）。
- 函数类型参数不能直接用 lambda 字面量做默认值 → 拆两个 init 重载。
- `InstanceStatus` 枚举比较需要 `@Derive[Equatable]`（默认无 `==`）。
- 测试真实子进程：cat 不退出时 `readToEnd` 会永久阻塞 → 循环 receive 计数收满 + `terminate(force: true)` + `wait()` 防僵尸。
- 测试挂起时用 `timeout 120 cjpm test` 包裹防死锁。
- 仓颉测试类内不能嵌套 class → 辅助类（FakeHost）放 @Test 类外顶层；测试辅助文件若无 @Test 宏会报 main 缺失 → 辅助类并入有 @Test 的测试文件。
- 无参 lambda 语法是 `{ => expr }`，不是 `{ () => expr }`。
- `JsonValue` 的 `[](key)` 返回 `?JsonValue`（Option），match 需 `case Some(JsonValue.String(k))`。
- `JsonRpcClient.call("method")` 无参重载是非泛型的，不能带 `<T, R>` 类型参数。
- 插件侧不能 `start()` + `serve()` 并用（双 receiveLoop 竞争读 transport）→ `start()` 后台接收 + 轮询 `isClosed()` 阻塞主线程。
- **仓颉 ConsoleReader 管道 bug（P3 最大坑）**：子进程被 launch 拉起后，`getStdIn().read(Array<Byte>)` 永久阻塞，`readln()` 正常 → 插件侧必须用 readln 逐行 + 换行帧协议。
- **双重去换行**：readln 已去掉行尾 `\n`，若再让 NewlineFraming 找 `\n` 永远解析不了 → LineStdioTransport.receive() 必须补回 `\n`。
- 测试类 `@Expect(exists(Path(...)))` 等路径断言；`File` 无 delete()，用 `std.fs.remove(Path(p))`。
- cjpm package-configuration 键：`"cordis_plugin.examples.e2e"`（无 organization 前缀），examples 目录需父包声明文件（examples.cj），子包目录名 = 包尾名（e2e 而非 e2e_plugin）。

## 待办 / 下一步

- [ ] P4：宏层 @plugin/@inject/@provide（参考 kux-cj @Crud、CJson @JsonSerializable）
- [ ] 后续增强：initialize 依赖不满足时插件保持 Waiting 重试（当前直接拒绝）；事件总线（emit/waterfall）；配置热更新监听
