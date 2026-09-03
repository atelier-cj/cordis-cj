# cordis_host

cordis-cj 插件化框架的**宿主侧**库：插件生命周期管理、进程 spawn 管理（stdio / UDS 双模式）、崩溃检测与自愈。

## 安装

```toml
[dependencies]
"ystyle::cordis_host" = "0.1.0"
```

## 依赖

- `cordis_core`：插件模型与事件总线
- `ystyle::jsonrpc` / `ystyle::jsonrpc_unix`：与插件进程通信（stdio / UDS）

## 仓库

完整代码与示例见 [cordis-cj](https://atomgit.com/ystyle/cordis-cj)。
