import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html

// The real schematic page will dispatch Msgs + hold Pixi state. For Phase (a)
// this is a pure view that lays out the keyed mount target; the outer app is
// responsible for calling pixi.mount_prototype() after first paint.
pub fn view(name: String) -> Element(msg) {
  html.div([attr.class("page page-schematic")], [
    html.div([attr.class("toolbar")], [
      html.a([attr.href("/v2/"), attr.class("back")], [html.text("← designs")]),
      html.span([attr.class("toolbar-title")], [html.text(name)]),
      html.span([attr.class("muted")], [html.text("Pixi-mount prototype")]),
    ]),
    html.div(
      [
        attr.id("pixi-root"),
        attr.attribute("data-pixi-key", "pixi-" <> name),
        attr.class("pixi-root"),
      ],
      [],
    ),
  ])
}
