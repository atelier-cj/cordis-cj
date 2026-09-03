# cordis_plugin

cordis-cj 插件化框架的**插件侧**库：`PluginRuntime`（stdio / UDS 模式）、宿主连接与生命周期协议。

## 安装

```toml
[dependencies]
"ystyle::cordis_plugin" = "0.1.0"
```

## 依赖

- `cordis_core`：插件模型与事件总线
- `ystyle::jsonrpc` / `ystyle::jsonrpc_stdio` / `ystyle::jsonrpc_unix`：与宿主通信

## 仓库

完整代码与示例见 [cordis-cj](https://atomgit.com/ystyle/cordis-cj)。
