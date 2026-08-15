package ystyle::cordis_core

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.HashMap

/**
 * initialize.params（插件 → 宿主）
 */
public class InitializeParams <: JsonSerializable & JsonDeserializable<InitializeParams> {
    public let id: String
    public let inject: Array<String>
    public let provide: Array<String>
    public let config: ?HashMap<String, JsonValue>

    public init(id: String, inject: Array<String>, provide: Array<String>,
                config!: ?HashMap<String, JsonValue> = None) {
        this.id = id
        this.inject = inject
        this.provide = provide
        this.config = config
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("inject").writeValue(this.inject)
        w.writeName("provide").writeValue(this.provide)
        if (let Some(cfg) <- this.config) {
            w.writeName("config")
            w.writeValue(cfg)
        }
        w.endObject()
    }

    public static func fromJson(r: JsonReader): InitializeParams {
        r.startObject()
        var id: ?String = None
        var inject: ?Array<String> = None
        var provide: ?Array<String> = None
        var config: ?HashMap<String, JsonValue> = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "id" => id = r.readValue<String>()
                case "inject" => inject = r.readValue<Array<String>>()
                case "provide" => provide = r.readValue<Array<String>>()
                case "config" => config = r.readValue<HashMap<String, JsonValue>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        InitializeParams(id.getOrThrow(), inject.getOrThrow(), provide.getOrThrow(), config: config)
    }
}

/**
 * initialize 响应 result（宿主 → 插件）
 */
public class InitializeResult <: JsonSerializable & JsonDeserializable<InitializeResult> {
    public let ok: Bool
    public let providers: HashMap<String, String>   // serviceKey -> 提供者插件 id

    public init(ok: Bool, providers: HashMap<String, String>) {
        this.ok = ok
        this.providers = providers
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("ok").writeValue(this.ok)
        w.writeName("providers").writeValue(this.providers)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): InitializeResult {
        r.startObject()
        var ok: ?Bool = None
        var providers: ?HashMap<String, String> = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "ok" => ok = r.readValue<Bool>()
                case "providers" => providers = r.readValue<HashMap<String, String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        InitializeResult(ok.getOrThrow(), providers.getOrThrow())
    }
}

/**
 * provide.params（插件 → 宿主）
 */
public class ProvideParams <: JsonSerializable & JsonDeserializable<ProvideParams> {
    public let key: String

    public init(key: String) {
        this.key = key
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("key").writeValue(this.key)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ProvideParams {
        r.startObject()
        var key: ?String = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "key" => key = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        ProvideParams(key.getOrThrow())
    }
}

/**
 * provide 响应 result（宿主 → 插件）：返回 undo_id，dispose 时凭此撤销
 */
public class ProvideResult <: JsonSerializable & JsonDeserializable<ProvideResult> {
    public let undoId: String

    public init(undoId: String) {
        this.undoId = undoId
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("undoId").writeValue(this.undoId)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ProvideResult {
        r.startObject()
        var undoId: ?String = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "undoId" => undoId = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        ProvideResult(undoId.getOrThrow())
    }
}

/**
 * dispose.params（宿主 → 插件）：按 undo_id 撤销指定服务
 */
public class DisposeParams <: JsonSerializable & JsonDeserializable<DisposeParams> {
    public let undoId: String

    public init(undoId: String) {
        this.undoId = undoId
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("undoId").writeValue(this.undoId)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): DisposeParams {
        r.startObject()
        var undoId: ?String = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "undoId" => undoId = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        DisposeParams(undoId.getOrThrow())
    }
}

/**
 * notify.params（宿主 → 插件）：广播依赖图变化
 */
public class NotifyParams <: JsonSerializable & JsonDeserializable<NotifyParams> {
    public let kind: String        // NotifyKind.DEPENDENCY_LOST | PROVIDER_CHANGED
    public let key: String         // 受影响的 serviceKey
    public let provider: ?String   // 新提供者插件 id（provider-changed 时）

    public init(kind: String, key: String, provider!: ?String = None) {
        this.kind = kind
        this.key = key
        this.provider = provider
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("kind").writeValue(this.kind)
        w.writeName("key").writeValue(this.key)
        if (let Some(p) <- this.provider) {
            w.writeName("provider").writeValue(p)
        }
        w.endObject()
    }

    public static func fromJson(r: JsonReader): NotifyParams {
        r.startObject()
        var kind: ?String = None
        var key: ?String = None
        var provider: ?String = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "kind" => kind = r.readValue<String>()
                case "key" => key = r.readValue<String>()
                case "provider" => provider = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        NotifyParams(kind.getOrThrow(), key.getOrThrow(), provider: provider)
    }
}

/**
 * log.params（插件 → 宿主，通知）
 */
public class LogParams <: JsonSerializable & JsonDeserializable<LogParams> {
    public let level: String   // LogLevel.TRACE|DEBUG|INFO|WARN|ERROR
    public let message: String

    public init(level: String, message: String) {
        this.level = level
        this.message = message
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("level").writeValue(this.level)
        w.writeName("message").writeValue(this.message)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): LogParams {
        r.startObject()
        var level: ?String = None
        var message: ?String = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "level" => level = r.readValue<String>()
                case "message" => message = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        LogParams(level.getOrThrow(), message.getOrThrow())
    }
}

/**
 * invoke.params（宿主转发服务调用；双向）
 */
public class InvokeParams <: JsonSerializable & JsonDeserializable<InvokeParams> {
    public let service: String
    public let method: String
    public let args: Array<JsonValue>

    public init(service: String, method: String, args: Array<JsonValue>) {
        this.service = service
        this.method = method
        this.args = args
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("service").writeValue(this.service)
        w.writeName("method").writeValue(this.method)
        w.writeName("args").writeValue(this.args)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): InvokeParams {
        r.startObject()
        var service: ?String = None
        var method: ?String = None
        var args: ?Array<JsonValue> = None
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "service" => service = r.readValue<String>()
                case "method" => method = r.readValue<String>()
                case "args" => args = r.readValue<Array<JsonValue>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        InvokeParams(service.getOrThrow(), method.getOrThrow(), args.getOrThrow())
    }
}
