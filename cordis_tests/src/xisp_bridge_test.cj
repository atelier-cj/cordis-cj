package ystyle::cordis_tests

import ystyle::cordis_xisp.JsonBridge
import ystyle::xisp.types.*
import jsonvalue.*
import std.collection.{HashMap, ArrayList}
import std.unittest.*
import std.unittest.testmacro.*

/**
 * JsonBridge 单元测试：JSON ↔ xisp LispValue 双向转换。
 *
 * 覆盖标量 / 整数还原 / 嵌套对象 / 列表 / nil / 不可序列化值（闭包、错误值）。
 */
@Test
class XispJsonBridgeTest {

    @TestCase
    func testScalarsRoundTrip(): Unit {
        // null → Nil → null
        match (JsonBridge.toJson(JsonBridge.toLisp(JsonValue.Null))) {
            case Some(JsonValue.Null) => ()
            case other => @Fail("null round-trip failed: ${other}")
        }
        // bool
        match (JsonBridge.toJson(JsonBridge.toLisp(JsonValue.Boolean(true)))) {
            case Some(JsonValue.Boolean(b)) => @Expect(b)
            case other => @Fail("bool round-trip failed: ${other}")
        }
        // string
        match (JsonBridge.toJson(JsonBridge.toLisp(JsonValue.String("hi")))) {
            case Some(JsonValue.String(s)) => @Expect(s, "hi")
            case other => @Fail("string round-trip failed: ${other}")
        }
        // 整数还原为 Int（而不是 10.0 浮点）
        match (JsonBridge.toLisp(JsonValue.Number(10.0))) {
            case LispValue.Int(i) => @Expect(i, 10)
            case other => @Fail("integer should map to Int, got ${other}")
        }
        // 非整数保留浮点
        match (JsonBridge.toLisp(JsonValue.Number(1.5))) {
            case LispValue.Float(f) => @Expect(f, 1.5)
            case other => @Fail("float should map to Float, got ${other}")
        }
    }

    @TestCase
    func testArrayToConsList(): Unit {
        // 数组 → Cons 链（真列表）
        let arr = JsonValue.Array(ArrayList<JsonValue>([
            JsonValue.Number(1.0), JsonValue.Number(2.0), JsonValue.Number(3.0),
        ]))
        let lisp = JsonBridge.toLisp(arr)
        // 链长 3，car 为 Int(1)
        match (lisp) {
            case LispValue.Cons(cell) =>
                match (cell.car) {
                    case LispValue.Int(i) => @Expect(i, 1)
                    case other => @Fail("expected Int head, got ${other}")
                }
            case other => @Fail("expected Cons, got ${other}")
        }
        // 回程：列表 → 数组
        match (JsonBridge.toJson(lisp)) {
            case Some(JsonValue.Array(items)) =>
                @Expect(items.size, 3)
                match (items[2]) {
                    case JsonValue.Number(n) => @Expect(n, 3.0)
                    case other => @Fail("expected number tail, got ${other}")
                }
            case other => @Fail("list → array failed: ${other}")
        }
    }

    @TestCase
    func testNestedObjectRoundTrip(): Unit {
        let inner = HashMap<String, JsonValue>()
        inner.add("port", JsonValue.Number(8080.0))
        inner.add("name", JsonValue.String("demo"))
        let outer = HashMap<String, JsonValue>()
        outer.add("server", JsonValue.fromObject(inner))
        outer.add("tags", JsonValue.Array(ArrayList<JsonValue>([
            JsonValue.String("a"), JsonValue.String("b"),
        ])))
        let json = JsonValue.fromObject(outer)

        let lisp = JsonBridge.toLisp(json)
        // 脚本侧 {...} 字面量即 HashMap，键为普通字符串
        match (lisp) {
            case LispValue.HashMap(m) =>
                @Expect(m.size, 2)
                @Assert(m.contains("server"))
            case other => @Fail("expected HashMap, got ${other}")
        }
        // 回程结构一致
        match (JsonBridge.toJson(lisp)) {
            case Some(JsonValue.Map(m)) =>
                match (m.get("server")) {
                    case Some(JsonValue.Map(innerBack)) =>
                        match (innerBack.get("port")) {
                            case Some(JsonValue.Number(n)) => @Expect(n, 8080.0)
                            case other => @Fail("nested port lost: ${other}")
                        }
                    case other => @Fail("nested object lost: ${other}")
                }
                match (m.get("tags")) {
                    case Some(JsonValue.Array(items)) => @Expect(items.size, 2)
                    case other => @Fail("nested array lost: ${other}")
                }
            case other => @Fail("nested round-trip failed: ${other}")
        }
    }

    @TestCase
    func testLongArrayDoesNotOverflowStack(): Unit {
        // 迭代构造（而非按元素递归）：长数组不耗栈
        let items = ArrayList<JsonValue>()
        for (i in 0..50000) {
            items.add(JsonValue.Number(Float64(i)))
        }
        let lisp = JsonBridge.toLisp(JsonValue.Array(items))
        match (JsonBridge.toJson(lisp)) {
            case Some(JsonValue.Array(back)) => @Expect(back.size, 50000)
            case other => @Fail("long array round-trip failed: ${other}")
        }
    }

    @TestCase
    func testNonSerializableValuesReturnNone(): Unit {
        // 原生函数（NativeFunc）没有 JSON 对应物
        let native = NativeFunc({ _ => LispValue.Nil })
        match (JsonBridge.toJson(native)) {
            case None => ()
            case Some(other) => @Fail("NativeFunc should not serialize, got ${other}")
        }
        // 错误值同样不可序列化（由 errorMessage 单独取消息）
        let err = LispValue.Error(XispError(ErrorType.RuntimeError, "boom"))
        match (JsonBridge.toJson(err)) {
            case None => ()
            case Some(other) => @Fail("Error value should not serialize, got ${other}")
        }
        @Expect(JsonBridge.errorMessage(err), Some("boom"))
    }

    @TestCase
    func testSymbolSerializedAsString(): Unit {
        // 符号按标识符文本序列化（脚本用 'done 作返回值是常见写法）
        match (JsonBridge.toJson(LispValue.Symbol("done"))) {
            case Some(JsonValue.String(s)) => @Expect(s, "done")
            case other => @Fail("symbol should serialize as string, got ${other}")
        }
    }

    @TestCase
    func testImpureListReturnsNone(): Unit {
        // 点对（非真列表）无法表示为 JSON 数组
        let dotted = consValue(LispValue.Int(1), LispValue.Int(2))
        match (JsonBridge.toJson(dotted)) {
            case None => ()
            case Some(other) => @Fail("dotted pair should not serialize, got ${other}")
        }
    }

    @TestCase
    func testStringFieldHelper(): Unit {
        let m = HashMap<String, JsonValue>()
        m.add("code", JsonValue.String("(+ 1 2)"))
        m.add("n", JsonValue.Number(1.0))
        let obj = JsonValue.fromObject(m)
        @Expect(JsonBridge.stringField(obj, "code"), Some("(+ 1 2)"))
        @Expect(JsonBridge.stringField(obj, "n"), None)
        @Expect(JsonBridge.stringField(obj, "absent"), None)
    }
}
