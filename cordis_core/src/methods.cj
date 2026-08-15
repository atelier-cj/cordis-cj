package ystyle::cordis_core

/**
 * JSON-RPC 2.0 方法名常量（协议定义见 docs/design-impl.md §4）
 */
public class Methods {
    public static let INITIALIZE: String = "initialize"      // 插件 → 宿主（请求）
    public static let INITIALIZED: String = "initialized"    // 宿主 → 插件（通知）
    public static let PROVIDE: String = "provide"            // 插件 → 宿主（请求，返回 undo_id）
    public static let DISPOSE: String = "dispose"            // 宿主 → 插件（请求）
    public static let NOTIFY: String = "notify"              // 宿主 → 插件（通知，依赖图变化）
    public static let LOG: String = "log"                    // 插件 → 宿主（通知）
    public static let INVOKE: String = "invoke"              // 宿主转发服务调用
    public static let PING: String = "ping"                  // 宿主 → 插件（请求，探活）
    public static let PONG: String = "pong"                  // 插件 → 宿主（响应 ping）

    private init() {}
}

/**
 * notify.params 的 kind 取值
 */
public class NotifyKind {
    public static let DEPENDENCY_LOST: String = "dependency-lost"
    public static let PROVIDER_CHANGED: String = "provider-changed"

    private init() {}
}

/**
 * log.params 的 level 取值
 */
public class LogLevel {
    public static let TRACE: String = "trace"
    public static let DEBUG: String = "debug"
    public static let INFO: String = "info"
    public static let WARN: String = "warn"
    public static let ERROR: String = "error"

    private init() {}
}
