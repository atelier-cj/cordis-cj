package ystyle::cordis_plugin.examples.inject_demo

import ystyle::cordis_plugin.*
import ystyle::cordis_plugin.macros.*
import jsonvalue.*

/**
 * @Inject 宏示例插件：注入 e2e 插件提供的 add 服务，通过代理调用
 *
 * 由宿主拉起；注入依赖 "add"（由其他插件提供）。
 * 宏生成：init(ctx) 构造函数注入 ServiceProxy + inject 依赖列表 ["add"]。
 */
@Plugin[]
public class InjectDemo {
    @Inject["add"]
    public var add: ServiceProxy

    @Provide["calc"]
    public func calc(args: Array<JsonValue>): JsonValue {
        // 通过代理调用远程 add 服务（宿主 invoke 转发）
        let result = this.add.call<JsonValue>("add", [JsonValue.Number(5.0), JsonValue.Number(6.0)])
        match (result) {
            case JsonValue.Number(n) => JsonValue.Number(n)
            case _ => JsonValue.Null
        }
    }
}
