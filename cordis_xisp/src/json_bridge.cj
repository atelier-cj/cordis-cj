package ystyle::cordis_xisp

import jsonvalue.*
import std.collection.*
import ystyle::xisp.types.*
import ystyle::xisp.core.eval.INTERRUPTED_MESSAGE

/**
 * `JsonValue` 与 xisp 的 `LispValue` 之间的双向转换。
 *
 * 对应关系（与 atelier PTC 实测锁定的映射一致）：
 * - `null` ↔ `Nil`
 * - `boolean` ↔ `Boolean`
 * - `number` ↔ `Int`（整数值）/ `Float`
 * - `string` ↔ `Str`
 * - `array` ↔ 列表（Cons 链）
 * - `object` ↔ `HashMap`（脚本里的 `{...}` 字面量直接就是 `LispValue.HashMap`）
 *
 * 转换函数/闭包/错误值等运行期对象没有 JSON 对应物，返回 `None` 由调用方处理。
 */
public class JsonBridge {

    /**
     * JSON → Lisp。
     */
    public static func toLisp(value: JsonValue): LispValue {
        match (value) {
            case JsonValue.Null => LispValue.Nil
            case JsonValue.Boolean(b) => LispValue.Boolean(b)
            case JsonValue.Number(n) => numberToLisp(n)
            case JsonValue.String(s) => LispValue.Str(s)
            case JsonValue.Array(items) => arrayToLisp(items)
            case JsonValue.Map(m) =>
                let bindings = HashMap<String, LispValue>()
                for ((k, v) in m) {
                    bindings.add(k, toLisp(v))
                }
                LispValue.HashMap(bindings)
        }
    }

    /**
     * 数组 → 列表。
     *
     * 迭代构造而非用 `types.list()`：后者按元素递归，长数组会耗尽栈
     * （atelier 实测 10 万元素即 OutOfMemoryError）。
     */
    private static func arrayToLisp(items: ArrayList<JsonValue>): LispValue {
        var result: LispValue = LispValue.Nil
        var i = items.size
        while (i > 0) {
            i = i - 1
            result = consValue(toLisp(items[i]), result)
        }
        result
    }

    /**
     * 数字 → Lisp。
     *
     * `JsonValue` 只有 `Number(Float64)`，但参数里的整数很常见，整数值一律
     * 还原为 `Int`，避免脚本拿到 `10.0` 后参与运算产生浮点结果。
     */
    private static func numberToLisp(n: Float64): LispValue {
        if (n >= -9223372036854775808.0 && n <= 9223372036854775807.0) {
            let asInt = Int64(n)
            if (Float64(asInt) == n) {
                return LispValue.Int(asInt)
            }
        }
        LispValue.Float(n)
    }

    /**
     * Lisp → JSON。无法表达为 JSON 的值返回 `None`。
     *
     * 严格而非宽容：把闭包悄悄转成字符串之类会掩盖脚本的错误，
     * 调用方应当把 `None` 当作「结果不可序列化」上报。
     */
    public static func toJson(value: LispValue): Option<JsonValue> {
        match (value) {
            case LispValue.Nil => Some(JsonValue.Null)
            case LispValue.Boolean(b) => Some(JsonValue.Boolean(b))
            case LispValue.Int(i) => Some(JsonValue.Number(Float64(i)))
            case LispValue.Float(f) => Some(JsonValue.Number(f))
            case LispValue.Str(s) => Some(JsonValue.String(s))
            // 符号按标识符文本序列化：脚本用 'done 之类的字面量作返回是常见写法
            case LispValue.Symbol(s) => Some(JsonValue.String(s))
            case LispValue.Cons(_) => listToJson(value)
            case LispValue.HashMap(m) =>
                let out = HashMap<String, JsonValue>()
                for ((k, v) in m) {
                    match (toJson(v)) {
                        case Some(j) => out.add(k, j)
                        case None => return None
                    }
                }
                Some(JsonValue.Map(out))
            // 过程、闭包、原生函数、错误值：没有 JSON 对应物
            case _ => None
        }
    }

    /**
     * Cons 链 → JSON 数组。非真列表（点对）返回 `None`。
     */
    private static func listToJson(value: LispValue): Option<JsonValue> {
        let items = ArrayList<JsonValue>()
        var current = value
        while (let Cons(cell) <- current) {
            match (toJson(cell.car)) {
                case Some(j) => items.add(j)
                case None => return None
            }
            current = cell.cdr
        }
        match (current) {
            case LispValue.Nil => Some(JsonValue.Array(items))
            // 点对不是列表，无法表示成 JSON 数组
            case _ => None
        }
    }

    /**
     * 取出 xisp 错误值的消息；非错误值返回 `None`。
     *
     * 求值结果里的错误以值表达（`LispValue.Error`），宿主据此转成异常
     * （cordis 侧按 INVOKE-ERROR 透传给调用方）。
     */
    public static func errorMessage(value: LispValue): Option<String> {
        match (value) {
            case LispValue.Error(e) => Some(e.message)
            case _ => None
        }
    }

    /**
     * 该错误值是否由求值中断产生（外层取消或超时）。
     */
    public static func isInterrupt(value: LispValue): Bool {
        match (value) {
            case LispValue.Error(e) => e.message == INTERRUPTED_MESSAGE
            case _ => false
        }
    }

    /**
     * 取出对象里的字符串字段；缺失或类型不符返回 `None`。
     */
    public static func stringField(value: JsonValue, name: String): Option<String> {
        match (value) {
            case JsonValue.Map(m) =>
                match (m.get(name)) {
                    case Some(JsonValue.String(s)) => Some(s)
                    case _ => None
                }
            case _ => None
        }
    }
}
