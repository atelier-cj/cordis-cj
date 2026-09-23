package ystyle::cordis_xisp.cli

import ystyle::cordis_xisp.XispPluginRuntime
import std.env.{getCommandLine, getVariable}
import std.fs.{Path, exists}

/**
 * Cordis xisp 插件运行时可执行入口。
 *
 * 用法（对应 cordis.toml 的 entry）：
 * ```toml
 * [[plugins]]
 * id = "my-lisp-plugin"
 * source = "./target/release/bin/ystyle::cordis_xisp.cli"
 * args = ["--script", "./my_plugin.lisp"]
 * provide = ["echo", "add"]
 * enabled = true
 * ```
 *
 * `--script` 必需；`id` / `inject` / `provide` 由宿主按 entry 以环境变量下发
 * （`CORDIS_PLUGIN_ID` / `CORDIS_PLUGIN_INJECT` / `CORDIS_PLUGIN_PROVIDE`），
 * 因此 cordis.toml 是这些元数据的唯一来源，不需要在 args 里重复声明。
 *
 * 独立运行（不经宿主）时可用同名命令行参数覆盖，便于手工调试：
 * - `--script <path>`（必需）插件脚本路径
 * - `--plugin-id <id>`（可选，缺省 = 脚本文件名去掉扩展名）
 * - `--provide <a,b>` / `--inject <a,b>`（可选，逗号分隔）
 */
main(): Int64 {
    let args = getCommandLine()

    let scriptPath = flagValue(args, "--script")
    match (scriptPath) {
        case Some(path) =>
            if (!exists(Path(path))) {
                eprintln("[cordis-xisp] script not found: ${path}")
                return 2
            }
            // 元数据优先级：宿主注入的环境变量 > 命令行参数 > 缺省推断
            let pluginId = match (envOrFlag("CORDIS_PLUGIN_ID", args, "--plugin-id")) {
                case Some(id) => id
                case None => defaultPluginId(path)
            }
            let provide = envListOrFlag("CORDIS_PLUGIN_PROVIDE", args, "--provide")
            let inject = envListOrFlag("CORDIS_PLUGIN_INJECT", args, "--inject")
            try {
                XispPluginRuntime.run(pluginId, inject, provide, path)
                return 0
            } catch (e: Exception) {
                // 初始化失败（脚本语法/运行错误、握手失败）→ 非零退出。
                // 宿主 PluginHost 会按崩溃自愈策略处理（报告 failed / 重启）。
                eprintln("[cordis-xisp] plugin '${pluginId}' failed: ${e.message}")
                return 1
            }
        case None =>
            eprintln("[cordis-xisp] missing required argument --script <path.lisp>")
            eprintln("usage: cordis_xisp --script <path> [--plugin-id <id>] [--provide a,b] [--inject a,b]")
            return 2
    }
}

/**
 * 取环境变量值；未设置或空串返回 None。
 */
private func envValue(name: String): Option<String> {
    match (getVariable(name)) {
        case Some(v) =>
            if (v == "") {
                None
            } else {
                Some(v)
            }
        case None => None
    }
}

/**
 * 环境变量优先，回退命令行参数。
 */
private func envOrFlag(envName: String, args: Array<String>, flag: String): Option<String> {
    match (envValue(envName)) {
        case Some(v) => Some(v)
        case None => flagValue(args, flag)
    }
}

/**
 * 逗号分隔列表：环境变量优先，回退命令行参数；缺省空数组。
 */
private func envListOrFlag(envName: String, args: Array<String>, flag: String): Array<String> {
    match (envOrFlag(envName, args, flag)) {
        case Some(value) => splitList(value)
        case None => Array<String>()
    }
}

/**
 * 取命令行参数值（--flag value）。
 */
private func flagValue(args: Array<String>, flag: String): Option<String> {
    var i: Int64 = 0
    while (i < args.size - 1) {
        if (args[i] == flag) {
            return Some(args[i + 1])
        }
        i++
    }
    None
}

/**
 * 逗号分隔字符串 → 数组（空串 → 空数组）。
 */
private func splitList(value: String): Array<String> {
    if (value == "") {
        Array<String>()
    } else {
        value.split(",")
    }
}

/**
 * 缺省插件 ID：脚本文件名去掉扩展名。
 */
private func defaultPluginId(scriptPath: String): String {
    // 取路径最后一段（兼容 / 分隔；不依赖 std.fs.Path API 差异）
    let parts = scriptPath.split("/")
    let base = parts[parts.size - 1]
    match (base.lastIndexOf(".")) {
        case Some(dot) =>
            if (dot > 0) { base[0..dot] } else { base }
        case None => base
    }
}
