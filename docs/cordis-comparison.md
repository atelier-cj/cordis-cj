# cordis-cj 与 Cordis 4.x 差距对比

> 对比基准：**Cordis 4.0.1**（DeepSeek Harness `vendor/cordis`，即 `@deepseek-ai/cordis`，dsh 实际运行版本）
> 参考源码：`/home/ystyle/Projects/deepseek-harness/vendor/cordis/src/`（context/fiber/registry/reflect/events/service/logger）
> 官方插件：`vendor/{loader,group,include,hmr,timer,logger-console}/`
> 论文：`docs/paper.pdf`（Revertible Effects and Reactive Coeffects）
> 更新日期：2026-02

## 1. Cordis 4.x 能力全景

### 1.1 核心运行时（`@deepseek-ai/cordis`）

| 子系统 | 关键 API | 语义 |
| :--- | :--- | :--- |
| **Context** | `extend(meta)` / `isolate(name,label)` / `intercept(name,config)` / `root` | 上下文即服务仓库；子上下文原型继承；isolate 隔离同名服务作用域；intercept 注入服务级配置 |
| **Fiber** | `effect()` / `dispose()` / `restart()` / `update(config)` / `await()` / `getEffects()` | 插件实例状态机 PENDING→LOADING→ACTIVE→FAILED→UNLOADING→DISPOSED；依赖未满足保持 PENDING 等待 |
| **Registry** | `ctx.plugin(plugin, config)` / `ctx.inject(deps, cb)` / `Inject` 装饰器 | 插件三形态（函数/类/apply 对象）；声明式依赖；`Config` schema 校验 |
| **Reflect** | `ctx.get` / `set` / `provide` / `accessor` / `mixin` | 服务注册与解析；`notify(names)` 依赖变更时自动重载依赖者 fiber |
| **Events** | `on` / `once` / `emit` / `parallel` / `serial` / `bail` / `waterfall` | 5 种派发模式 + 上下文过滤 + prepend/global 选项；事件随 fiber 自动清理 |
| **Service** | `class X extends Service` / `[check]` / `[invoke]` / `[resolveConfig]` | 类即服务：`super(ctx, name)` 自动注册；可用性谓词；可调用服务；拦截配置合并 |
| **Logger** | `ctx.logger(name)` | 命名日志器，`%s`/`%C` 格式化，彩色输出 |

### 1.2 官方插件（Cordis 生态）

| 插件 | 职责 |
| :--- | :--- |
| `loader` | 配置驱动加载：EntryTree/EntryGroup、config 持久化回写、`!!js` 表达式插值、inject 合并 |
| `group` | 嵌套插件组（EntryGroup） |
| `include` | 配置 include 文件（YAML/JSON），配置持久化 |
| `hmr` | 热模块替换：chokidar 监听 + 模块依赖图 + reload |
| `timer` | `ctx.timeout/interval/throttle/debounce` 可撤销定时器 |
| `logger-console` | 控制台日志输出 |

### 1.3 dsh 实际使用规模（packages/ 统计）

- `ctx.effect`：**140 文件**；`ctx.on(`：**223 文件** —— 可逆效果 + 事件是核心范式
- `extends Service`：**134 个**服务子类（ctx.llm / ctx.tools / ctx.sessions ...）
- `ctx.provide`：**178 文件**；`inject:` 声明：**567 处**；`Config =` schema：**136 处**
- 事件模式：`waterfall`/`parallel`/`serial`/`bail`/`once` 全部在用（tool pipeline、agent dispatch、session、UI 等）

## 2. 逐项对比

| # | 能力 | Cordis 4.x | cordis-cj | 差距 |
| :--- | :--- | :--- | :--- | :--- |
| 1 | 依赖未满足 Waiting 重试 | PENDING 状态，服务就绪自动启动 | initialize 依赖缺失**直接拒绝** | 🔴 语义级 |
| 2 | 依赖变更自动通知重载 | `reflect.notify()` → 依赖者 fiber 重载 | 无（服务变更依赖者无感知） | 🔴 语义级 |
| 3 | 事件派发模式 | emit / parallel / serial / bail / waterfall | 仅 emit（同步广播） | 🔴 高频 |
| 4 | 事件 `once` / prepend / global / 过滤 | 完整 | 无 | 🟡 |
| 5 | Service 基类（类即服务） | 134 个服务子类 | key + handler 模式 | 🟡 高频 |
| 6 | Config schema 校验 | standard-schema + ValidationError（含路径） | config 透传不校验 | 🟡 |
| 7 | Fiber 状态机 | 6 态 + await/restart/update | Starting/Active/Unloading/Failed + 崩溃自愈 | 🟡 |
| 8 | 配置热更新 | loader `internal/update` + 持久化回写 | reconcile 循环（文件变更重读） | 🟡 |
| 9 | 服务隔离 `isolate` | 同名服务多实现按作用域分隔 | 无 | 🟢 |
| 10 | 服务拦截 `intercept` | 服务级配置合并 | 无 | 🟢 |
| 11 | `accessor` / `mixin` | ctx 属性动态扩展 | 无 | 🟢 |
| 12 | effect 诊断树 `getEffects()` | 效果元数据树 | 无（仅 disposer 列表） | 🟢 |
| 13 | async / generator effect | 完整 | 仅同步 disposer | 🟢 |
| 14 | 嵌套插件组 `group` | 支持 | 无 | 🟢 |
| 15 | 配置 include / 继承 | 支持 | 无 | 🟢 |
| 16 | timer 服务 | timeout/interval/throttle/debounce | 无 | 🟢 |
| 17 | 命名 Logger | `ctx.logger(name)` + 格式化 | `ctx.log(level, msg)` | 🟢 |
| 18 | HMR 热重载 | 模块级热替换 | 进程隔离下 HMR=重启（已有崩溃自愈） | ⚪ 不适用 |
| 19 | 进程隔离 | ❌（同进程） | ✅ 卸载杀进程回收资源 | ✅ 优势 |
| 20 | 崩溃自愈 | ❌（进程级） | ✅ | ✅ 优势 |
| 21 | 双传输 stdio/UDS | ❌ | ✅ | ✅ 优势 |
| 22 | 宏零样板（@Plugin/@Provide/@Inject） | 装饰器（TS） | ✅ 仓颉宏 | ✅ 对等 |
| 23 | 泛型类型安全 invoke/registerHandler | TS 类型 | ✅ 仓颉泛型 | ✅ 对等 |
| 24 | 可逆效果（基础） | ✅ | ✅ ctx.effect | ✅ 对等 |

🔴 = 语义核心差距（论文重点 / dsh 高频）｜🟡 = 重要功能差距｜🟢 = 增强性差距｜⚪ = 不适用

## 3. 差距分析（论文视角）

论文《Revertible Effects and Reactive Coeffects》的核心主张与对应状态：

| 论文概念 | 含义 | cordis-cj 状态 |
| :--- | :--- | :--- |
| **Revertible Effects**（§3.1） | 效果可逆：注册即得 disposer，卸载逆序执行 | ✅ 基础已实现（ctx.effect），缺 async/generator/诊断树 |
| **Reactive Coeffects**（§3.2） | 上下文感知依赖：服务规格化 + 变更通知 | 🔴 **半实现**：依赖声明（inject/provide）有，**变更通知（notification）缺失** |
| **Specification and Notification**（§3.2.2） | 服务就绪通知 + 依赖者响应 | 🔴 initialize 一次握手后无持续响应 |
| **Isolation and Interception**（§3.2.3） | 服务作用域隔离 + 配置拦截 | 🔴 未实现 |
| **Context 范式**（§3.3） | 统一上下文，代理解析服务 | 🟡 PluginContext 是简化版（无代理/无 get/set/accessor） |
| **组件生命周期**（§4） | PENDING/LOADING/ACTIVE/FAILED/UNLOADING | 🟡 简化版（Starting/Active/Unloading） |
| **Withdrawal/Iteration/Asynchrony/Failure**（§4.3） | 卸载中的并发转换 | 🟡 未建模（terminate 直接杀进程简化了语义） |
| **声明式配置**（§5.2） | loader + 配置持久化 | 🟡 ConfigLoader + reconcile 有，缺热更新/持久化回写 |
| **HMR**（§5.2.2） | 热替换 | ⚪ 进程隔离下等价为重启 |

## 4. 建议补齐路线（按价值/成本排序）

### 第一阶段：语义核心（对齐论文 + dsh 高频）

1. **依赖 Waiting 重试**：initialize 依赖缺失 → 插件保持 PENDING 而非拒绝；宿主定时/事件驱动重试握手（`InstanceStatus.Pending`）
2. **事件总线 v2**：`emit`（现有）/ `parallel` / `serial` / `bail` / `waterfall` + `once` + 上下文过滤 —— 这是 dsh 使用最密集的能力，也是 progress-tracking 既有待办
3. **依赖变更通知**：服务撤销/变更时宿主通知依赖者（`notify` 通知已存在，补"依赖者自动重启/重握手"）

### 第二阶段：服务系统完善

4. **Service 类化**：`class DbService extends Service { name="db"; check(){...} }` 抽象（宿主侧提供 base class），替代裸 key+handler 的一部分场景
5. **Config schema 校验**：插件声明 Config（TOML 字段白名单/类型校验），加载失败给路径化错误
6. **配置热更新**：reconcile 检测到 entry.config 变更 → 重启该插件（进程隔离下天然安全）

### 第三阶段：增强

7. `isolate` 服务隔离（同名服务多实例，如多租户）
8. `intercept` 服务级配置
9. `accessor` / `mixin`（ctx 动态属性）
10. `getEffects()` 诊断树
11. timer / 命名 Logger

### 明确不做

- **模块级 HMR**：进程隔离的卸载=杀进程，插件代码更新只需重启进程（reconcile 已支持），模块热替换与进程隔离架构冲突
- **同进程插件**：论文虽支持（Koishi 场景），但 dsh 需要进程沙箱（landlock），保持进程隔离是正确选择

## 5. 参考

- dsh vendor/cordis 源码：`/home/ystyle/Projects/deepseek-harness/vendor/cordis/src/`
- dsh cordis 教程：`/home/ystyle/Projects/deepseek-harness/docs/cordis-primer.md`、`docs/cordis-api/`
- Cordis 官方仓库：`/home/ystyle/Projects/Cangjie/ref/cordis/`（cordiverse/cordis，同源）
- 论文：`/home/ystyle/Projects/deepseek-harness/docs/paper.pdf`
