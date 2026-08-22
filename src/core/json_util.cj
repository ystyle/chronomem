package chronomem.core

import std.io.ByteBuffer
import stdx.encoding.json.stream.*

// 固定结构 json.stream 序列化助手（与 llm_api.util / atelier.util 同款，core 自包含不依赖 LLM 库）。
public func toJsonString<T>(obj: T): String where T <: JsonSerializable {
    let buf = ByteBuffer()
    let w = JsonWriter(buf)
    w.writeValue(obj)
    w.flush()
    String.fromUtf8(buf.bytes())
}

public func fromJsonString<T>(json: String): T where T <: JsonDeserializable<T> {
    let buf = ByteBuffer(json.toArray())
    let r = JsonReader(buf)
    T.fromJson(r)
}
