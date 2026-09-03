# cordis-cj 仓颉插件化框架（宿主 + 插件运行时 + 通信协议）

## 仓颉语言
- 在上下文压缩后，如果没有仓颉语法相关的，需要马上使用 `cangjie_mem_list` 工具加载所有仓颉语言级记忆
- 在仓颉 api 和手册可以使用 `cangjie_docs` 相关工具查找，在 `cangjie-mem` 没有的直接在文档里查找，不要猜 api 和语法
- 在提示语法错误时重新使用 `cangjie-mem` 加载语言级记忆
- match 的 case 后不能接 `{}`，case 后直接写多行表达式而不需要 `{}`

## 任务指南
- **不要考虑时间，不要简化算法，不要简化测试，这项目是自己的产品，按最好的来搞**
- 在实现功能总结后，需要更新 `docs/` 下对应设计/进度文档，并把值得注意的内容记录到 `cangjie-mem` 项目级记忆
- 新功能、新特性一定要写单元测试（以仓颉单元测试为主）
- 测试发现的新问题需要解决，且要添加新用例到单元测试里
- 不要在项目外创建仓颉单文件测试，非 cjpm 项目没法导入当前项目

## 发布约定（中心仓）

- 只发布**库包**：`cordis_core`（核心）→ `cordis_host`（宿主侧）→ `cordis_plugin`（插件侧），按依赖顺序发版
- **测试包与示例包不需要发布到中心仓**：`cordis_tests`（测试）、`cordis_examples`（示例）仅用于本地构建与集成验证（`cjpm test`），不进发版清单、不做 bundle/publish
- 发版顺序：`cordis_core` 先发（含 registry 索引同步），`cordis_host`/`cordis_plugin` 依赖它随后发；workspace 内验证用 path 依赖，发布前切回 registry 版本号

## 项目结构

```
cordis-cj/
├── cjpm.toml          # workspace 根配置
├── cordis_core/       # 核心库：插件模型、事件总线、配置、RPC 客户端封装
├── cordis_host/       # 宿主侧库：PluginManager、插件生命周期、进程管理
├── cordis_plugin/     # 插件侧库：PluginRuntime、宿主通信
├── cordis_examples/   # 示例（e2e 演示插件/宿主，不发中心仓）
├── cordis_tests/      # 集成测试（不发中心仓）
└── docs/              # 设计文档
```

## 常用命令

```shell
# 环境
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"

# 编译（workspace 根目录）
cjpm build -j 16

# 运行所有测试
cjpm test -j 16 --no-progress

# 运行指定测试
cjpm test --show-all-output --filter 'TestName.*'

# 清理构建缓存
cjpm clean
```

## 关于 LSP 报错

如果代码看起来没错，但 LSP 报错：
- 源码文件：执行 `cjpm build` 编译
- 测试文件：执行 `cjpm test --no-run` 编译
