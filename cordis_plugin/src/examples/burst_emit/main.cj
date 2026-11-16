package ystyle::cordis_plugin.examples.burst_emit

import ystyle::cordis_plugin.*
import jsonvalue.*

/**
 * 高频事件发布者：在一次 invoke 的处理线程里连续 emit N 条事件。
 *
 * 存在的理由：插件的上行事件通道必须能承受「一个回合里成百上千条增量」——
 * 这是 harness 事件流（文本增量、工具调用分片）的真实形态。早期实测在该路径上
 * 首帧之后连接即断，数据面因此改走 stderr；本插件把那条路径重新变成可测的：
 * 宿主侧统计收到的条数，并验证连接在之后仍可用。
 *
 * 参数：go(n)            → 向 burst/tick 发 n 条（通知式派发）
 *       go(n, eventName) → 向指定事件名发 n 条（并发用例需要两条互不相同的流）
 *       ser()            → 一次 serial 派发（请求式，用来验证事件追踪开关同时覆盖两条路径）
 */
main(): Int64 {
    let handler = { ctx: PluginContext =>
        ctx.registerHandler("burst", { method, args =>
            if (method == "ser") {
                let _ = ctx.serial("burst/ser", [JsonValue.String("p")])
                return JsonValue.Boolean(true)
            }
            let n = match (args[0]) {
                case JsonValue.Number(x) => Int64(x)
                case _ => Int64(1)
            }
            let event = if (args.size > 1) {
                match (args[1]) {
                    case JsonValue.String(s) => s
                    case _ => "burst/tick"
                }
            } else {
                "burst/tick"
            }
            for (i in 0..n) {
                ctx.emit(event, [JsonValue.Number(Float64(i))])
            }
            JsonValue.Number(Float64(n))
        })
        ctx.log("info", "burst-emit ready")
    }
    PluginRuntime.run("burst-emit", [], ["burst"], handler)
    return 0
}
