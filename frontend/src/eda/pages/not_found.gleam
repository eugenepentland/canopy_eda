import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

pub fn view() -> Element(msg) {
  html.div([attr.class("page page-404")], [
    html.h1([], [html.text("Not found")]),
    html.p([], [
      html.a([attr.href("/v2/")], [html.text("Back to designs")]),
    ]),
  ])
}
