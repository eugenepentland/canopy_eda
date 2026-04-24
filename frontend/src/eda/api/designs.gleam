import eda/api/client.{type ApiError}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}

pub type Design {
  Design(
    name: String,
    title: String,
    sections: List(String),
    instance_count: Int,
    net_count: Int,
    mtime: Int,
    build_ok: Bool,
  )
}

pub fn list() -> Promise(Result(List(Design), ApiError)) {
  client.get_json("/api/designs", decode.list(decoder()))
}

fn decoder() -> decode.Decoder(Design) {
  use name <- decode.field("name", decode.string)
  use title <- decode.field("title", decode.string)
  use sections <- decode.field("sections", decode.list(decode.string))
  use instance_count <- decode.field("instance_count", decode.int)
  use net_count <- decode.field("net_count", decode.int)
  use mtime <- decode.field("mtime", decode.int)
  use build_ok <- decode.field("build_ok", decode.bool)
  decode.success(Design(
    name:,
    title:,
    sections:,
    instance_count:,
    net_count:,
    mtime:,
    build_ok:,
  ))
}
