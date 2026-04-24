import eda/api/client.{type ApiError}
import eda/api/designs.{type Design}
import gleam/int
import gleam/list
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

pub type Loaded {
  Loading
  Loaded(designs: List(Design))
  Failed(err: ApiError)
}

pub fn view(state: Loaded) -> Element(msg) {
  html.div([attr.class("page page-index")], [
    html.h1([], [html.text("Designs")]),
    case state {
      Loading -> html.p([attr.class("muted")], [html.text("Loading…")])
      Failed(err) ->
        html.p([attr.class("error")], [html.text(describe_error(err))])
      Loaded([]) ->
        html.p([attr.class("muted")], [html.text("No designs found in src/.")])
      Loaded(designs) ->
        html.div([attr.class("designs-grid")], list.map(designs, card))
    },
  ])
}

fn card(d: Design) -> Element(msg) {
  let parts_word = case d.instance_count {
    1 -> " part"
    _ -> " parts"
  }
  let nets_word = case d.net_count {
    1 -> " net"
    _ -> " nets"
  }
  let title_text = case d.title, d.title == d.name {
    "", _ -> d.name
    _, True -> d.name
    _, False -> d.title
  }
  let stats_line = case d.build_ok {
    True ->
      int.to_string(d.instance_count)
      <> parts_word
      <> " · "
      <> int.to_string(d.net_count)
      <> nets_word
    False -> "build failed"
  }
  html.div([attr.class("design-card")], [
    html.div([attr.class("design-card-header")], [
      html.div([attr.class("design-card-title")], [html.text(title_text)]),
      case title_text == d.name {
        True -> element.none()
        False ->
          html.div([attr.class("design-card-name")], [html.text(d.name <> ".sexp")])
      },
    ]),
    html.div([attr.class("design-card-stats")], [html.text(stats_line)]),
    section_chips(d.sections),
    html.div([attr.class("design-card-links")], [
      html.a(
        [attr.class("design-card-link"), attr.href("/v2/schematics/" <> d.name)],
        [html.text("Schematic")],
      ),
      html.a(
        [attr.class("design-card-link"), attr.href("/v2/pcb/" <> d.name)],
        [html.text("PCB")],
      ),
      html.a(
        [attr.class("design-card-link"), attr.href("/v2/review/" <> d.name)],
        [html.text("Review")],
      ),
    ]),
  ])
}

fn section_chips(sections: List(String)) -> Element(msg) {
  case sections {
    [] -> element.none()
    _ -> {
      let max_chips = 6
      let #(shown, overflow) = split_at(sections, max_chips, [], 0)
      let chips = list.map(shown, chip)
      let more_label = case overflow {
        0 -> []
        n -> [
          html.span([attr.class("section-chip-more")], [
            html.text("+" <> int.to_string(n) <> " more"),
          ]),
        ]
      }
      html.div([attr.class("design-card-sections")], list.append(chips, more_label))
    }
  }
}

fn chip(s: String) -> Element(msg) {
  html.span([attr.class("section-chip")], [html.text(s)])
}

fn split_at(
  xs: List(String),
  max: Int,
  acc: List(String),
  count: Int,
) -> #(List(String), Int) {
  case xs, count >= max {
    [], _ -> #(list.reverse(acc), 0)
    rest, True -> #(list.reverse(acc), list.length(rest))
    [x, ..rest], False -> split_at(rest, max, [x, ..acc], count + 1)
  }
}

fn describe_error(err: ApiError) -> String {
  case err {
    client.NetworkError(m) -> "Network error: " <> m
    client.HttpStatus(code) -> "HTTP " <> int.to_string(code)
    client.Unauthorized -> "Unauthorized — please sign in"
    client.DecodeError(m) -> "Decode error: " <> m
  }
}
