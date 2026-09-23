# 设计：xisp 脚本插件（cordis_xisp）

> **状态:** 已实现（`feat/xisp-plugin`）
> **相关:** [`cordis_xisp/README.md`](../cordis_xisp/README.md)（使用文档）、
> [design-impl.md](design-impl.md)（cordis 协议实现）、
> atelier 的 PTC 设计（工作区外 `atelier/docs/plans/2026-09-21-ptc-xisp-design.md`）

## 一、目标

让 Cordis 插件可以是**一个 `.lisp` 脚本**而不是编译产物：脚本顶层求值即插件
初始化，之后由宿主事件驱动（invoke / 事件 / 定时器）。

不变量：

- 协议层零改动：复用 `PluginRuntime.run`，宿主侧 `PluginHost` / 调和器 /
  信任闸门 / 事件注册表全部不变；
- 不削弱现有语义：依赖拓扑（inject）、服务注册（provide）、热卸载（效果逆序
  撤销）、崩溃自愈（进程退出 → 宿主重启）与仓颉插件一致；
- 脚本环境最小权限：只给纯函数，不给文件/进程/模块/eval。

## 二、为什么是「插件进程内嵌 xisp」而不是别的形态

| 形态 | 结论 |
| :--- | :--- |
| **插件进程内嵌 xisp**（本设计） | ✅ 复用 cordis 的进程隔离与协议；脚本是插件业务逻辑的载体 |
| 宿主进程内嵌 xisp 跑脚本 | ❌ 与 cordis 的进程隔离模型冲突：脚本异常/死循环会拖住宿主；卸载无法回收 |
| xisp 直接实现 JSON-RPC 协议 | ❌ 脚本要手写握手/帧协议，且 stdio 帧与 xisp 的 IO 能力边界冲突 |
| 只把 xisp 当「配置 DSL」 | ❌ 得不到控制流（事件回调、定时器、嵌套调用），价值仅剩声明 |

进程隔离是 cordis 的既有承诺（静态语言无法卸载模块，所以插件 = 子进程），
xisp 插件沿用同一条路：**OS 级隔离由架构提供，脚本层再叠一层能力最小化**。

## 三、与 atelier PTC 的关系

同一套「宿主把能力以绑定形式注入 xisp 环境」的模式，两个投影：

| 维度 | atelier PTC | cordis_xisp |
| :--- | :--- | :--- |
| 进程 | 宿主进程内嵌 | **插件独立进程** |
| 执行模型 | 一次性跑一段程序 | **长驻**：顶层求值 = 初始化，回调挂起等事件 |
| 调用方向 | 脚本 → 工具（同步） | 双向：宿主 → 脚本回调（invoke/事件/定时器）+ 脚本 → 宿主（invoke/emit） |
| 并发 | 单线程（子调用串行） | 协议层多线程（INVOKE 在 spawn 线程），脚本调用需串行化 |
| 安全边界 | 环境最小化 | 环境最小化 **+ OS 级进程隔离** |

可复用的是**结论**而非代码：`registerPure` 的边界、错误即值语义、JsonValue ↔
LispValue 映射（含长数组迭代构造避免栈溢出）、以及「唯一可靠边界是环境里没有」
这条实测结论。

## 四、关键设计决策

### D1 脚本回调经表达式树 `(apply fn (quote args))` 调用

xisp 没有公开的「调用任意函数值」API，但：

- `apply` 是特殊形式（`evalApply`），接受函数值 + 参数列表；
- `Procedure` / `Closure` / `NativeFunc` 值在求值器里**自求值**（`evalInner` 的
  兜底分支 `case _ => expr`）；
- `quote` 让宿主构造的实参列表不被当作函数调用求值。

因此宿主侧「调用脚本注册的 lambda」= 构造
`(apply <proc> (quote <arg-list>))` 表达式树交给 `Evaluator.eval`。这条路被
PTC 实测锁定过，语义（错误即值短路传播等）与脚本内调用一致。

### D2 脚本调用串行化 + 独立求值器

xisp 的 `Environment` 非线程安全（`HashMap` 绑定、无同步原语），而 cordis 的
INVOKE / events-dispatch 处理在独立线程执行。设计：

- 所有进脚本的调用经 `scriptLock`（可重入 `Mutex`）串行化；
- 每次调用新建 `Evaluator(this.env)`：共享的是环境（绑定），不共享求值器实例
  状态（栈深度、编译挂起标志等）。

### D3 同步请求等待期间释放脚本锁（解死锁）

**问题**：脚本 handler 内 `(cordis::invoke ...)` 是同步请求，宿主转发可能回到
**本插件**（调用自己的另一个服务）。若此时持有脚本锁，宿主派发回来的 INVOKE
在另一个线程上等同一把锁 → 死锁。

**解法**：`invoke` / `serial` / `bail` / `waterfall` 这几个同步请求绑定在等待
宿主响应前 `unlock()`，响应后 `lock()`（异常路径同样恢复锁）。等价于把
「等待协议响应」移出临界区。

**代价**：等待窗口内其他回调可能并发进入脚本。这是「可重入窗口」，与 xisp 单线程
求值模型的最小冲突面；文档化为「脚本不应依赖回调间的共享可变状态」。
`testNestedInvokeNoDeadlock` 用真实宿主 + 真实进程守住该路径（限时轮询保护，
死锁则测试失败而不是挂死）。

### D4 元数据经环境变量下发（cordis.toml 单一来源）

插件进程需要知道自己的 `id` / `inject` / `provide`：`initialize` 请求要带
`inject` / `provide`，而宿主 `awaitActive` 按 `entry.provide` 等待服务注册。

若让插件在命令行参数里重复声明，就有「cordis.toml entry 与 args 两处不一致」的
footgun。因此由宿主在 `PluginManager` 拉起进程时按 entry 注入环境变量：

```
CORDIS_PLUGIN_ID      = entry.id
CORDIS_PLUGIN_PROVIDE = entry.provide 逗号连接
CORDIS_PLUGIN_INJECT  = entry.inject  逗号连接
```

实测 `std.process.launch` 的 `environment` 参数是**追加**在继承环境之上
（PATH 等保留），因此不消费这些变量的既有插件不受影响。独立运行时可用同名
命令行参数覆盖，便于手工调试。

### D5 声明的 provide 缺实现时留痕

宿主按 `entry.provide` 等注册，静默缺失的现象是「插件起不来」（握手等待超时）
而不是 invoke 报错。故脚本初始化后比对「已注册 handler 的 Key」与声明的
provide，缺失则写 **stderr**（宿主 `PluginManager.forwardStderr` 可转发进宿主
日志）。只诊断不失败：脚本可能在运行期（事件/定时器回调里）才注册 handler。

## 五、脚本 API 面

绑定全部注册在 `cordis::` 命名空间下（显式全名，避开 xisp 内部两套命名空间
分隔符的分歧）：

| 分类 | 绑定 |
| :--- | :--- |
| 服务 | `register-handler` / `invoke` / `provide` / `dispose` / `plugin-id` |
| 事件 | `on` / `once` / `emit` / `serial` / `bail` / `waterfall` |
| 日志/效果 | `log` / `effect` / `config` |
| 定时器 | `timeout` / `interval` / `throttle` / `debounce`（均返回可调用的 `cancel` 函数） |

`println` 等输出被 `registerPure(output: ...)` 接到宿主日志——**stdout 是协议帧
通道**，脚本输出绝不能落进程 stdout。

## 六、安全模型

| 层 | 机制 |
| :--- | :--- |
| 进程/OS | cordis 进程隔离（插件 = 子进程，卸载即杀，资源由 OS 回收） |
| 环境 | 干净 `Environment` + `registerPure`：无文件/进程/模块/`eval` 能力 |
| 协议 | 服务调用经宿主转发，受宿主侧服务索引与依赖拓扑约束 |
| 资源 | 定时器可撤销；订阅随卸载退订；效果逆序撤销 |

不采用（实测无效）：xisp 的 `setAllowedFunctions` / `blockFunction`（可被
`apply` / `map` / `for-each` 绕过）、路径白名单（只挂在部分 IO 函数上）、
`setMaxMemory`（死代码）。结论与 PTC 一致：**唯一可靠边界是「环境里没有」**。

## 七、测试策略

| 层 | 文件 | 覆盖 |
| :--- | :--- | :--- |
| 单元 | `cordis_tests/src/xisp_bridge_test.cj` | JsonValue ↔ LispValue：标量 / 整数还原 / 嵌套 / 长数组不爆栈 / 不可序列化值 / 符号 / 点对 / stringField |
| 集成（内存双端） | `cordis_tests/src/xisp_runtime_test.cj` | handler 注册与 invoke / 错误传播为 `INVOKE-ERROR` / provide 返回 undo_id / 配置下发 / interval 定时器 / cancel 撤销 / 语法错误初始化失败 / 插件 ID |
| e2e（真实进程） | `cordis_tests/src/xisp_e2e_test.cj` | 宿主 ↔ 插件进程 invoke（含 whoami 验证环境变量通道）/ 双插件事件路由 / 嵌套 invoke 无死锁 / 缺失脚本失败路径与 stderr 转发 |

内存双端用 `MemoryDuplexTransport` 对接宿主 client 与插件 server，无需子进程；
e2e 用真实 `ystyle::cordis_xisp.cli` 二进制 + `examples/*.lisp`。

## 八、已知边界 / 后续

- 脚本回调无超时（与原生插件一致）：宿主 invoke 超时放弃等待，脚本线程继续跑完。
  若需要，可给 `callScript` 装 `Evaluator.setInterruptChecker`（xisp 已具备协作式
  中断检查点），按「脚本回调预算」中断；
- 同步请求窗口内的共享可变状态需脚本自行负责（见 D3）；
- `cordis::proxy`（远程服务代理句柄）未提供：`cordis::invoke` 已覆盖；
  若需要 `(let db (cordis::proxy "db"))` 形式，可返回捕获 service key 的 lambda；
- 不支持跨调用持久内核：脚本状态在插件进程生命周期内存在（与 atelier PTC 的
  「每次全新环境」不同——这里是长驻插件，状态本来就要保留）。
