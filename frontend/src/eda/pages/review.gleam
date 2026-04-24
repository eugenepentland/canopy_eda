import eda/api/client.{type ApiError}
import eda/api/review.{
  type AssertionReport, type BomEntry, type BomGroup, type Review,
  type SectionReport, type Status, type Summary,
}
import gleam/int
import gleam/list
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

pub type Loaded {
  Loading(name: String)
  Loaded(doc: Review)
  Failed(name: String, err: ApiError)
}

pub fn view(state: Loaded) -> Element(msg) {
  case state {
    Loading(name) ->
      html.div([attr.class("page page-review")], [
        toolbar(name),
        html.p([attr.class("muted")], [html.text("Loading review for " <> name <> "…")]),
      ])

    Failed(name, err) ->
      html.div([attr.class("page page-review")], [
        toolbar(name),
        html.p([attr.class("error")], [html.text(describe_error(err))]),
      ])

    Loaded(doc) ->
      html.div([attr.class("page page-review")], [
        toolbar(doc.design_name),
        header(doc),
        summary_banner(doc.summary),
        sections_list(doc.sections),
        bom_table(doc.bom),
        assertions_list(doc.assertions),
      ])
  }
}

fn toolbar(name: String) -> Element(msg) {
  html.div([attr.class("toolbar")], [
    html.a([attr.class("back"), attr.href("/v2/")], [html.text("← designs")]),
    html.span([attr.class("toolbar-title")], [html.text(name)]),
    html.span([attr.class("muted")], [html.text("review")]),
    html.a(
      [attr.class("toolbar-link"), attr.href("/v2/schematics/" <> name)],
      [html.text("Schematic")],
    ),
    html.a([attr.class("toolbar-link"), attr.href("/v2/pcb/" <> name)], [
      html.text("PCB"),
    ]),
  ])
}

fn header(doc: Review) -> Element(msg) {
  let title = case doc.title {
    "" -> doc.design_name
    t -> t
  }
  html.div([attr.class("review-header")], [
    html.h1([], [html.text(title)]),
    html.div([attr.class("muted")], [
      html.text(doc.design_name <> ".sexp · generated " <> doc.generated_at),
    ]),
  ])
}

fn summary_banner(s: Summary) -> Element(msg) {
  let status_class = case s.status {
    review.Pass -> "banner banner-ok"
    review.Warn -> "banner banner-warn"
    review.Fail -> "banner banner-fail"
    review.Unknown -> "banner banner-warn"
  }
  let status_label = status_label(s.status)
  html.div([attr.class(status_class)], [
    html.div([attr.class("banner-label")], [html.text(status_label)]),
    html.div([attr.class("banner-stats")], [
      stat("Sections", s.section_count),
      stat("Instances", s.instance_count),
      stat("Nets", s.net_count),
      stat("Errors", s.violation_error),
      stat("Warnings", s.violation_warning),
      stat("Asserts ✓", s.assertion_pass),
      stat("Asserts ✗", s.assertion_fail),
    ]),
  ])
}

fn status_label(s: Status) -> String {
  case s {
    review.Pass -> "All checks passed"
    review.Warn -> "Warnings"
    review.Fail -> "Failing checks"
    review.Unknown -> "Unknown status"
  }
}

fn stat(label: String, n: Int) -> Element(msg) {
  html.div([attr.class("stat")], [
    html.span([attr.class("stat-n")], [html.text(int.to_string(n))]),
    html.span([attr.class("stat-label")], [html.text(label)]),
  ])
}

fn sections_list(sections: List(SectionReport)) -> Element(msg) {
  case sections {
    [] -> element.none()
    _ ->
      html.section([attr.class("review-section")], [
        html.h2([], [html.text("Sections")]),
        html.div([attr.class("sections-grid")], list.map(sections, section_card)),
      ])
  }
}

fn section_card(s: SectionReport) -> Element(msg) {
  html.div(
    [
      attr.class("section-card"),
      attr.attribute("data-status", s.status),
      attr.id("sec-" <> s.slug),
    ],
    [
      html.div([attr.class("section-card-title")], [html.text(s.name)]),
      case s.description {
        "" -> element.none()
        d -> html.div([attr.class("section-card-desc")], [html.text(d)])
      },
      html.div([attr.class("section-card-meta")], [
        html.span([], [
          html.text(int.to_string(s.instance_count) <> " instance(s)"),
        ]),
        html.span([attr.class("section-status")], [html.text(s.status)]),
      ]),
    ],
  )
}

fn bom_table(groups: List(BomGroup)) -> Element(msg) {
  case groups {
    [] -> element.none()
    _ ->
      html.section([attr.class("review-section")], [
        html.h2([], [html.text("BOM")]),
        html.table([attr.class("bom-table")], [
          html.thead([], [
            html.tr([], [
              html.th([], [html.text("Ref")]),
              html.th([], [html.text("Component")]),
              html.th([], [html.text("Value")]),
              html.th([], [html.text("Footprint")]),
            ]),
          ]),
          html.tbody([], list.flat_map(groups, group_rows)),
        ]),
      ])
  }
}

fn group_rows(g: BomGroup) -> List(Element(msg)) {
  list.map(g.entries, entry_row)
}

fn entry_row(e: BomEntry) -> Element(msg) {
  html.tr([], [
    html.td([attr.class("cell-ref")], [html.text(e.ref_des)]),
    html.td([], [html.text(e.component)]),
    html.td([], [html.text(e.value)]),
    html.td([attr.class("cell-fp")], [html.text(e.footprint)]),
  ])
}

fn assertions_list(list_: List(AssertionReport)) -> Element(msg) {
  case list_ {
    [] -> element.none()
    _ ->
      html.section([attr.class("review-section")], [
        html.h2([], [html.text("Assertions")]),
        html.ul([attr.class("assertions")], list.map(list_, assertion_row)),
      ])
  }
}

fn assertion_row(a: AssertionReport) -> Element(msg) {
  let icon = case a.status {
    "pass" -> "✓"
    "warn" -> "⚠"
    "fail" -> "✗"
    _ -> "·"
  }
  html.li([attr.class("assertion assertion-" <> a.status)], [
    html.span([attr.class("assertion-icon")], [html.text(icon)]),
    html.span([], [html.text(a.message)]),
  ])
}

fn describe_error(err: ApiError) -> String {
  case err {
    client.NetworkError(m) -> "Network error: " <> m
    client.HttpStatus(code) -> "HTTP " <> int.to_string(code)
    client.Unauthorized -> "Unauthorized — please sign in"
    client.DecodeError(m) -> "Decode error: " <> m
  }
}
