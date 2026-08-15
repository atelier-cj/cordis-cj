macro package ystyle::cordis_plugin.macros

import std.ast.*
// 重导出运行时符号：宏展开生成的代码直接引用，使用者仅导入宏包即可编译
public import ystyle::cordis_plugin.PluginRuntime
public import ystyle::cordis_plugin.PluginContext

/**
 * @provide 属性宏：标记插件类中对外提供服务的 public 方法
 *
 * 用法：
 * ```cangjie
 * @plugin
 * public class MyPlugin {
 *     @provide["echo"]
 *     public func echo(args: Array<JsonValue>): JsonValue {
 *         // 业务逻辑
 *     }
 * }
 * ```
 *
 * @provide 通过 setItem 把 (服务 key, 方法名) 上报给外层 @plugin 宏，
 * 自身展开后保持原方法声明不变。
 */
public macro Provide(attr: Tokens, input: Tokens): Tokens {
    assertParentContext("Plugin")
    // 解析 @provide["service-key"] 属性
    let serviceKey = parseAttrString(attr, "provide")
    // 解析方法声明
    let funcDecl = FuncDecl(input)
    let methodName = funcDecl.identifier.value
    // 上报给外层 @plugin 宏
    setItem("serviceKey", serviceKey)
    setItem("methodName", methodName)
    // 保持原方法不变
    return input
}

/**
 * @plugin 属性宏：把类标记为 Cordis 插件，自动生成 main + 运行时启动
 *
 * 展开逻辑：
 * 1. 收集类内所有 @provide 方法（getChildMessages）
 * 2. 生成 main：PluginRuntime.run(类名, [], [keys...], { ctx =>
 *        let __plugin = 类名()
 *        ctx.registerHandler(key, { method, args => __plugin.方法(args) })
 *    })
 * 3. 原类保持不变
 */
public macro Plugin(attr: Tokens, input: Tokens): Tokens {
    let classDecl = ClassDecl(input)
    let className = classDecl.identifier.value
    let classNameToken = Token(TokenKind.IDENTIFIER, className)

    // 收集 @provide 子宏消息
    let provides = getChildMessages("Provide")

    // 构造服务 key 数组：[ "key1", "key2" ]
    var keyTokens = Tokens()
    keyTokens = keyTokens + Token(TokenKind.LSQUARE)
    var first = true
    for (msg in provides) {
        if (!first) {
            keyTokens = keyTokens + Token(TokenKind.COMMA)
        }
        first = false
        let key = msg.getString("serviceKey")
        keyTokens = keyTokens + Token(TokenKind.STRING_LITERAL, key)
    }
    keyTokens = keyTokens + Token(TokenKind.RSQUARE)

    // 构造 handler 内的注册语句列表（拼接为 Tokens）
    var registrations = Tokens()
    var firstReg = true
    for (msg in provides) {
        if (!firstReg) {
            registrations = registrations + Token(TokenKind.NL)
        }
        firstReg = false
        let serviceKey = msg.getString("serviceKey")
        let methodName = msg.getString("methodName")
        let methodToken = Token(TokenKind.IDENTIFIER, methodName)
        registrations = registrations + quote(
            ctx.registerHandler($(serviceKey), { method, args => __plugin.$(methodToken)(args) })
        )
    }

    // 生成 main 函数（作为独立进程入口）
    // className 作为字符串字面量传入 PluginRuntime.run
    let nameLiteral = Token(TokenKind.STRING_LITERAL, className)
    let mainTokens = quote(
        main(): Int64 {
            PluginRuntime.run($(nameLiteral), [], $(keyTokens), { ctx =>
                let __plugin = $(classNameToken)()
                $(registrations)
            })
            return 0
        }
    )

    // 将 main 追加到类声明之后（顶层函数）
    let classTokens = classDecl.toTokens()
    return classTokens + mainTokens
}

/**
 * 解析属性参数中的字符串：@provide["key"]
 */
func parseAttrString(attr: Tokens, macroName: String): String {
    let s = attr.toString()
    let trimmed = s.trimStart().trimEnd()
    // 去掉可能的 [] 和引号
    var content = trimmed
    if (content.startsWith("[")) {
        content = content[1..]
    }
    if (content.endsWith("]")) {
        content = content[0..(content.size - 1)]
    }
    content = content.trimStart().trimEnd()
    if (content.startsWith("\"")) {
        content = content[1..]
    }
    if (content.endsWith("\"")) {
        content = content[0..(content.size - 1)]
    }
    if (content.isEmpty()) {
        throw Exception("@${macroName} requires a string key, e.g. @${macroName}[\"service-key\"]")
    }
    content
}
