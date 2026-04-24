import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}
import gleam/json
import gleam/result

pub type ApiError {
  NetworkError(String)
  HttpStatus(Int)
  Unauthorized
  DecodeError(String)
}

@external(javascript, "../../api_ffi.mjs", "get_text")
fn ffi_get_text(url: String) -> Promise(String)

@external(javascript, "../../api_ffi.mjs", "post_text")
fn ffi_post_text(
  url: String,
  body: String,
  content_type: String,
) -> Promise(String)

/// GET a JSON endpoint and decode the body with `decoder`. The returned
/// Promise resolves to `Ok(T)` on 2xx + successful decode, `Error(ApiError)`
/// otherwise.
pub fn get_json(path: String, decoder: decode.Decoder(a)) -> Promise(Result(a, ApiError)) {
  ffi_get_text(path)
  |> promise.map(decode_body(_, decoder))
  |> promise.rescue(classify_fetch_error)
}

/// POST a JSON body and decode the response.
pub fn post_json(
  path: String,
  body: String,
  decoder: decode.Decoder(a),
) -> Promise(Result(a, ApiError)) {
  ffi_post_text(path, body, "application/json")
  |> promise.map(decode_body(_, decoder))
  |> promise.rescue(classify_fetch_error)
}

fn decode_body(body: String, decoder: decode.Decoder(a)) -> Result(a, ApiError) {
  case json.parse(body, decoder) {
    Ok(v) -> Ok(v)
    Error(err) -> Error(DecodeError(describe_parse_error(err)))
  }
}

fn describe_parse_error(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedByte(b) -> "unexpected byte: " <> b
    json.UnexpectedSequence(s) -> "unexpected sequence: " <> s
    json.UnableToDecode(_) -> "decoder failed"
  }
}

// Distinguish unauthorized / HTTP status / network errors using the
// `http_status` field we attach in api_ffi.mjs.
fn classify_fetch_error(err: Dynamic) -> Result(a, ApiError) {
  let status_decoder = decode.at(["http_status"], decode.int)
  case decode.run(err, status_decoder) {
    Ok(401) -> Error(Unauthorized)
    Ok(code) -> Error(HttpStatus(code))
    Error(_) -> {
      let msg_decoder = decode.at(["message"], decode.string)
      case decode.run(err, msg_decoder) {
        Ok(m) -> Error(NetworkError(m))
        Error(_) -> Error(NetworkError("unknown fetch error"))
      }
    }
  }
}

/// Flatten a `Result(Result(a, ApiError), ApiError)` into `Result(a, ApiError)`.
/// Useful when you compose two API calls with `promise.map`.
pub fn flatten(r: Result(Result(a, ApiError), ApiError)) -> Result(a, ApiError) {
  result.flatten(r)
}
