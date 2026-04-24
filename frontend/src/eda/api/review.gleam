import eda/api/client.{type ApiError}
import gleam/dynamic/decode
import gleam/javascript/promise.{type Promise}

pub type Status {
  Pass
  Warn
  Fail
  Unknown
}

pub type Summary {
  Summary(
    status: Status,
    section_count: Int,
    instance_count: Int,
    net_count: Int,
    violation_error: Int,
    violation_warning: Int,
    violation_info: Int,
    assertion_pass: Int,
    assertion_warn: Int,
    assertion_fail: Int,
  )
}

pub type SectionReport {
  SectionReport(
    name: String,
    slug: String,
    status: String,
    description: String,
    instance_count: Int,
  )
}

pub type BomEntry {
  BomEntry(
    ref_des: String,
    component: String,
    value: String,
    footprint: String,
  )
}

pub type BomGroup {
  BomGroup(prefix: String, entries: List(BomEntry))
}

pub type AssertionReport {
  AssertionReport(message: String, status: String)
}

pub type Review {
  Review(
    design_name: String,
    title: String,
    generated_at: String,
    summary: Summary,
    sections: List(SectionReport),
    bom: List(BomGroup),
    assertions: List(AssertionReport),
  )
}

pub fn fetch(name: String) -> Promise(Result(Review, ApiError)) {
  client.get_json("/api/review/" <> name, decoder())
}

fn decoder() -> decode.Decoder(Review) {
  use design_name <- decode.field("design_name", decode.string)
  use title <- decode.field("title", decode.string)
  use generated_at <- decode.field("generated_at", decode.string)
  use summary <- decode.field("summary", summary_decoder())
  use sections <- decode.field("sections", decode.list(section_decoder()))
  use bom <- decode.field("bom", decode.list(bom_group_decoder()))
  use assertions <- decode.field("assertions", decode.list(assertion_decoder()))
  decode.success(Review(
    design_name:,
    title:,
    generated_at:,
    summary:,
    sections:,
    bom:,
    assertions:,
  ))
}

fn summary_decoder() -> decode.Decoder(Summary) {
  use status <- decode.field("status", decode.string)
  use section_count <- decode.field("section_count", decode.int)
  use instance_count <- decode.field("instance_count", decode.int)
  use net_count <- decode.field("net_count", decode.int)
  use vio <- decode.field("violations", violations_decoder())
  use asrt <- decode.field("assertions", assertion_counts_decoder())
  let #(verr, vwarn, vinfo) = vio
  let #(apass, awarn, afail) = asrt
  decode.success(Summary(
    status: parse_status(status),
    section_count:,
    instance_count:,
    net_count:,
    violation_error: verr,
    violation_warning: vwarn,
    violation_info: vinfo,
    assertion_pass: apass,
    assertion_warn: awarn,
    assertion_fail: afail,
  ))
}

fn violations_decoder() -> decode.Decoder(#(Int, Int, Int)) {
  use e <- decode.field("error", decode.int)
  use w <- decode.field("warning", decode.int)
  use i <- decode.field("info", decode.int)
  decode.success(#(e, w, i))
}

fn assertion_counts_decoder() -> decode.Decoder(#(Int, Int, Int)) {
  use p <- decode.field("pass", decode.int)
  use w <- decode.field("warn", decode.int)
  use f <- decode.field("fail", decode.int)
  decode.success(#(p, w, f))
}

fn parse_status(s: String) -> Status {
  case s {
    "pass" -> Pass
    "warn" -> Warn
    "fail" -> Fail
    _ -> Unknown
  }
}

fn section_decoder() -> decode.Decoder(SectionReport) {
  use name <- decode.field("name", decode.string)
  use slug <- decode.field("slug", decode.string)
  use status <- decode.field("status", decode.string)
  use description <- decode.field("description", decode.string)
  use instance_count <- decode.field("instance_count", decode.int)
  decode.success(SectionReport(name:, slug:, status:, description:, instance_count:))
}

fn bom_group_decoder() -> decode.Decoder(BomGroup) {
  use prefix <- decode.field("prefix", decode.string)
  use entries <- decode.field("entries", decode.list(bom_entry_decoder()))
  decode.success(BomGroup(prefix:, entries:))
}

fn bom_entry_decoder() -> decode.Decoder(BomEntry) {
  use ref_des <- decode.field("ref_des", decode.string)
  use component <- decode.field("component", decode.string)
  use value <- decode.field("value", decode.string)
  use footprint <- decode.field("footprint", decode.string)
  decode.success(BomEntry(ref_des:, component:, value:, footprint:))
}

fn assertion_decoder() -> decode.Decoder(AssertionReport) {
  use message <- decode.field("message", decode.string)
  use status <- decode.field("status", decode.string)
  decode.success(AssertionReport(message:, status:))
}
