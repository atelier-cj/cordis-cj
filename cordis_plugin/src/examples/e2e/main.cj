package ystyle::cordis_plugin.examples.e2e

import ystyle::cordis_plugin.*
import jsonvalue.*

/**
 * 端到端测试插件：提供两个服务（echo/add），供宿主拉起验证全流程
 *
 * 运行方式：作为独立可执行文件被宿主 PluginManager.launch 拉起，
 * 通过 stdio（换行帧）与宿主 JSON-RPC 通信。
 */
main(): Int64 {
    PluginRuntime.run("e2e-plugin", [], ["echo", "add"], { ctx =>
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
    })
    return 0
}
