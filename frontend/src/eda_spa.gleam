import eda/api/client.{type ApiError}
import eda/api/designs.{type Design}
import eda/api/review as api_review
import eda/ffi/pixi
import eda/pages/index as page_index
import eda/pages/not_found as page_not_found
import eda/pages/review as page_review
import eda/pages/schematic as page_schematic
import eda/router.{type Route}
import gleam/javascript/promise
import gleam/option.{type Option, None, Some}
import gleam/uri.{type Uri}
import lustre
import lustre/attribute as attr
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import modem

pub type Model {
  Model(
    route: Route,
    pixi: Option(pixi.PixiApp),
    designs: page_index.Loaded,
    review: page_review.Loaded,
  )
}

pub type Msg {
  UriChanged(Uri)
  PixiMounted(pixi.PixiApp)
  DesignsLoaded(Result(List(Design), ApiError))
  ReviewLoaded(String, Result(api_review.Review, ApiError))
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  let initial_route = case modem.initial_uri() {
    Ok(u) -> router.parse(u)
    Error(_) -> router.Index
  }
  #(
    Model(
      route: initial_route,
      pixi: None,
      designs: page_index.Loading,
      review: page_review.Loading(""),
    ),
    effect.batch([modem.init(UriChanged), on_enter(initial_route)]),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    UriChanged(u) -> {
      let next = router.parse(u)
      let teardown = case model.pixi {
        Some(app) -> effect_sync(fn() { pixi.destroy(app) })
        None -> effect.none()
      }
      let model1 = case next {
        router.Review(name) ->
          Model(..model, route: next, pixi: None, review: page_review.Loading(name))
        router.Index ->
          Model(..model, route: next, pixi: None, designs: page_index.Loading)
        _ -> Model(..model, route: next, pixi: None)
      }
      #(model1, effect.batch([teardown, on_enter(next)]))
    }

    PixiMounted(app) -> #(Model(..model, pixi: Some(app)), effect.none())

    DesignsLoaded(result) -> {
      let loaded = case result {
        Ok(designs) -> page_index.Loaded(designs)
        Error(err) -> page_index.Failed(err)
      }
      #(Model(..model, designs: loaded), effect.none())
    }

    ReviewLoaded(name, result) -> {
      // Ignore stale responses from a prior route.
      let is_current = case model.route {
        router.Review(current) -> current == name
        _ -> False
      }
      case is_current {
        False -> #(model, effect.none())
        True -> {
          let loaded = case result {
            Ok(doc) -> page_review.Loaded(doc)
            Error(err) -> page_review.Failed(name, err)
          }
          #(Model(..model, review: loaded), effect.none())
        }
      }
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  case model.route {
    router.Index -> page_index.view(model.designs)
    router.Schematic(name) -> page_schematic.view(name)
    router.Pcb(name) -> page_schematic.view(name)
    router.Review(_) -> page_review.view(model.review)
    router.Library -> placeholder("Library")
    router.Account -> placeholder("Account")
    router.AuthLogin -> placeholder("Auth: login")
    router.AuthRegister -> placeholder("Auth: register")
    router.AuthManage -> placeholder("Auth: manage")
    router.OauthAuthorize -> placeholder("OAuth authorize")
    router.NotFound -> page_not_found.view()
  }
}

fn placeholder(label: String) -> Element(Msg) {
  html.div([attr.class("page page-placeholder")], [
    html.h1([], [html.text(label)]),
    html.p([attr.class("muted")], [
      html.text("Not implemented yet — SPA port in progress."),
    ]),
  ])
}

fn on_enter(route: Route) -> Effect(Msg) {
  case route {
    router.Index -> fetch_designs()
    router.Schematic(name) -> mount_pixi(name)
    router.Pcb(name) -> mount_pixi(name)
    router.Review(name) -> fetch_review(name)
    _ -> effect.none()
  }
}

fn fetch_designs() -> Effect(Msg) {
  effect.from(fn(dispatch) {
    let _ =
      designs.list()
      |> promise.tap(fn(r) { dispatch(DesignsLoaded(r)) })
    Nil
  })
}

fn fetch_review(name: String) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    let _ =
      api_review.fetch(name)
      |> promise.tap(fn(r) { dispatch(ReviewLoaded(name, r)) })
    Nil
  })
}

fn mount_pixi(name: String) -> Effect(Msg) {
  effect.after_paint(fn(dispatch, _) {
    let _ =
      pixi.mount_prototype("pixi-root", "Pixi-mount prototype · " <> name)
      |> promise.tap(fn(app) { dispatch(PixiMounted(app)) })
    Nil
  })
}

fn effect_sync(f: fn() -> Nil) -> Effect(Msg) {
  effect.from(fn(_dispatch) { f() })
}
