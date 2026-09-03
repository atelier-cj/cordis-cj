# cordis_core

cordis-cj 插件化框架的核心库：插件模型、事件总线、配置加载与 RPC 客户端封装，平台无关。

## 特性

- 插件模型：插件描述/清单、事件订阅发布
- 事件总线：进程内事件分发
- 配置：服务参数与插件配置管理
- 通信基座：基于 `ystyle::jsonrpc` 的 RPC 封装

## 安装

```toml
[dependencies]
"ystyle::cordis_core" = "0.1.0"
```

## 仓库

完整代码与示例见 [cordis-cj](https://atomgit.com/ystyle/cordis-cj)（含 `cordis_host` / `cordis_plugin` / `cordis_examples` / `cordis_tests`）。
