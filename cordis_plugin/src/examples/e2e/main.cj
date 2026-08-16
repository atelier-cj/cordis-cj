package ystyle::cordis_plugin.examples.e2e

import ystyle::cordis_plugin.*
import jsonvalue.*

/**
 * 端到端测试插件：提供两个服务（echo/add），供宿主拉起验证全流程
 *
 * 运行方式：作为独立可执行文件被宿主 PluginManager.launch 拉起。
 * 支持两种传输模式（宿主配置决定）：
 * - stdio（默认）：通过 stdin/stdout 换行帧与宿主 JSON-RPC 通信
 * - uds：宿主传入 --uds <path> 参数，插件连接 Unix Domain Socket
 *   与宿主通信（Content-Length 帧）
 */
main(args: Array<String>): Int64 {
    let handler = { ctx: PluginContext =>
        // 注册 echo 服务实现：原样返回第一个参数
        ctx.registerHandler("echo", { method, args =>
            if (args.size > 0) {
                args[0]
            } else {
                JsonValue.Null
            }
        })
        // 注册 add 服务实现：两个数字相加
        ctx.registerHandler("add", { method, args =>
            let a = match (args[0]) { case JsonValue.Number(n) => n; case _ => 0.0 }
            let b = match (args[1]) { case JsonValue.Number(n) => n; case _ => 0.0 }
            JsonValue.Number(a + b)
        })
        ctx.log("info", "e2e plugin ready")
    }

    match (PluginRuntime.parseUdsArg(args)) {
        case Some(path) =>
            PluginRuntime.runUds(path, "e2e-plugin", [], ["echo", "add"], handler)
        case None =>
            PluginRuntime.run("e2e-plugin", [], ["echo", "add"], handler)
    }
    return 0
}
