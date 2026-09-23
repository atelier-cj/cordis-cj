# cordis_xisp —— 用 xisp（Lisp）脚本编写 Cordis 插件

`cordis_xisp` 是 Cordis 的 **xisp 插件运行时**：一个通用可执行文件，
它复用 `PluginRuntime.run` 完成 cordis 协议（握手 / provide / invoke 路由 /
事件派发），在业务 handler 里嵌入 [xisp](https://atomgit.com/ystyle/xisp)
解释器，把 `PluginContext` 的能力以 `cordis::*` 命名空间绑定注入脚本环境。

于是插件可以是一个 `.lisp` 文件，而不是一个编译产物：

```toml
# cordis.toml
[[plugins]]
id = "lisp-echo"
source = "./target/release/bin/ystyle::cordis_xisp.cli"
args = ["--script", "./cordis_xisp/examples/echo.lisp"]
provide = ["echo", "add", "whoami"]
enabled = true
```

```lisp
;; echo.lisp
(cordis::register-handler "echo" (lambda (method args)
  (if (> (length args) 0) (car args) nil)))
```

## 架构

```
宿主进程                              插件进程（ystyle::cordis_xisp.cli）
┌──────────────────────┐   stdio/UDS   ┌──────────────────────────────────┐
│ PluginHost           │◀─────────────▶│ PluginRuntime（cordis 协议）      │
│  serviceIndex        │  JSON-RPC 2.0 │   ├─ XispPluginRuntime           │
│  eventRegistry       │               │   │    ├─ 干净 Environment       │
│  信任闸门/调和器      │               │   │    ├─ registerPure（纯函数） │
└──────────────────────┘               │   │    ├─ cordis::* 绑定         │
                                       │   │    └─ 加载 .lisp 脚本        │
                                       │   └─ ServiceRegistry（可逆效果）  │
                                       └──────────────────────────────────┘
```

脚本顶层表达式求值 = **插件初始化**（注册服务 handler、事件监听器、定时器）；
之后脚本回调（invoke / 事件 / 定时器）由宿主事件驱动。

这与 atelier 的 PTC（Programmatic Tool Calling）是同一套「宿主把能力以绑定形式
注入 xisp 环境」模式的另一个投影：atelier 是宿主进程内嵌 xisp 跑一段程序；
这里是插件进程内嵌 xisp 跑一个长驻脚本 + 事件驱动。

## 脚本 API

全部绑定在 `cordis::` 命名空间下。

### 服务

| 脚本调用 | 说明 |
| :--- | :--- |
| `(cordis::register-handler "key" (lambda (method args) ...))` | 注册服务实现，宿主 `invoke` 转发到本插件时调用脚本 lambda |
| `(cordis::invoke "service" "method" args-list)` | 经宿主转发调用其他插件的服务（返回结果） |
| `(cordis::provide "key")` | 运行时向宿主注册服务，返回 `undo_id` |
| `(cordis::dispose "undo-id")` | 撤销指定服务，返回 `#t` / `#f` |
| `(cordis::plugin-id)` | 返回插件 ID（宿主按 `entry.id` 下发） |

handler 的 `args` 是参数列表（xisp 真列表）；返回值必须是可序列化为 JSON 的值
（`nil` / 布尔 / 数字 / 字符串 / 列表 / `{...}` 哈希表）。脚本错误以错误值表达，
handler 返回错误值时宿主收到 `INVOKE-ERROR: ...`。

### 事件

| 脚本调用 | 说明 |
| :--- | :--- |
| `(cordis::on "event" (lambda (args) ...))` | 订阅事件，返回订阅 id（订阅是效果，卸载自动退订） |
| `(cordis::once "event" (lambda (args) ...))` | 一次性订阅 |
| `(cordis::emit "event" args-list)` | 发布事件（宿主扇出，不等待订阅者） |
| `(cordis::serial "event" args-list)` | 按序派发，遇 bail 值停止并返回 |
| `(cordis::bail "event" args-list)` | 同 `serial` |
| `(cordis::waterfall "event" args-list)` | 洋葱链派发 |

### 日志与效果

| 脚本调用 | 说明 |
| :--- | :--- |
| `(cordis::log "info" "message")` | 发日志到宿主（`trace`/`debug`/`info`/`warn`/`error`） |
| `(cordis::effect (lambda () ...))` | 注册可逆效果，插件卸载时逆序执行 |
| `(cordis::config)` | 插件私有配置（宿主 `[plugins.config]` 下发，转成哈希表） |
| `(cordis::timeout ms (lambda () ...))` | 一次性定时器，返回 `cancel` 函数（`(cancel)` 撤销） |
| `(cordis::interval ms (lambda () ...))` | 周期定时器，返回 `cancel` 函数 |
| `(cordis::throttle ms (lambda () ...))` | 节流，返回触发函数 |
| `(cordis::debounce ms (lambda () ...))` | 防抖，返回触发函数 |

`println` / `print` 等输出被接到宿主日志通道（**不会**写到进程 stdout——
stdout 是插件↔宿主的协议帧通道）。

## provide / inject 的声明

**cordis.toml 是唯一来源**：宿主按 `entry` 把元数据以环境变量
（`CORDIS_PLUGIN_ID` / `CORDIS_PLUGIN_PROVIDE` / `CORDIS_PLUGIN_INJECT`）
下发给插件进程，插件用它发 `initialize` 请求并注册服务。脚本**不需要**重复声明
id / provide / inject。

独立运行（不经宿主）调试时，可用同名命令行参数覆盖：
`--plugin-id` / `--provide a,b` / `--inject a,b`（优先级：环境变量 > 命令行参数）。

若声明的 `provide` 在脚本初始化后没有对应 handler，插件会在 **stderr** 留一条
诊断（宿主 `PluginManager` 的 logger 可转发到宿主日志）——因为宿主按
`entry.provide` 等待服务注册，静默缺失的现象是「插件起不来」而不是 invoke 报错。

## 能力边界与安全

脚本环境是**干净 `Environment` + `registerPure`**：只有算术、比较、逻辑、列表、
高阶函数（`map` / `filter` / `reduce`）、谓词、哈希表、字符串与宏。

**没有**文件、进程、模块加载与 `eval` 能力；需要这些请通过工具/服务调用。
边界用「环境里不存在」表达，而不是「注册后过滤」——xisp 的权限检查对
`eval` / `apply` / `map` 等特殊形式无效（它们先于检查执行），且函数值可作为
参数传递，只有「不注册」才是可靠的禁止。

进程隔离由 Cordis 架构本身提供（插件是独立子进程，卸载即杀进程）。

## 并发模型

- xisp 的 `Environment` **非线程安全** → 所有进脚本的调用（handler / 监听器 /
  定时器回调）经运行时内部锁串行化；
- 每次脚本调用使用**独立求值器**实例（避免求值器实例状态跨线程竞态）；
- 同步请求类绑定（`cordis::invoke` / `serial` / `bail` / `waterfall`）在等待宿主
  响应前**释放脚本锁**，收到响应后重新获取——解开「脚本回调内嵌套调用自己插件
  服务」的跨线程死锁（cordis 的 INVOKE 处理在独立线程执行，若持锁等待，宿主把
  回调派发回本插件时会阻塞在同一把锁上）。该路径有 e2e 用例守住
  （`cordis_tests/src/xisp_e2e_test.cj` 的 `testNestedInvokeNoDeadlock`）。

已知边界：

- 同步请求等待窗口内，其他回调可能并发进入脚本；脚本不应依赖回调之间的
  共享可变状态（纯函数回调安全）；
- 脚本回调默认无超时：与原生仓颉插件一致，宿主 invoke 超时会放弃等待，
  但脚本线程会继续跑完。

## 示例

| 示例 | 说明 |
| :--- | :--- |
| [`examples/echo.lisp`](examples/echo.lisp) | echo / add / whoami + 事件订阅 |
| [`examples/nested_invoke.lisp`](examples/nested_invoke.lisp) | 嵌套服务调用（脚本锁释放窗口） |
| [`examples/event_emit.lisp`](examples/event_emit.lisp) | 启动时发布事件 + 事件回显 |

## 测试

```shell
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm test -j 16 --no-progress

# 仅 xisp 相关（顶层函数风格用例名，--filter 是通配符，用子串写法）
cjpm test --show-all-output --filter '*Xisp*'
```

覆盖：JsonBridge 双向转换（标量 / 整数还原 / 嵌套 / 长数组 / 不可序列化值）、
内存双端（handler 注册与 invoke / 错误传播 / provide / 配置 / 定时器与撤销 /
语法错误初始化失败 / 插件 ID）、真实进程 e2e（宿主 ↔ 插件进程的 invoke、
双插件事件路由、嵌套 invoke 无死锁、缺失脚本的失败路径与 stderr 转发）。

## 依赖说明

`ystyle::xisp` 目前以 **path 依赖**（`../../xisp`）引入：运行所需的
`registerPure` 纯函数子集、求值中断检查点、严格解析在 xisp v0.4.0 之后才进
master，尚未发版。**xisp 发版后**这里应改为版本号依赖，之后 `cordis_xisp`
才能随之发中心仓。
