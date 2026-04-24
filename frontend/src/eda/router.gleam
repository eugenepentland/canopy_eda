import gleam/list
import gleam/string
import gleam/uri.{type Uri}

pub type Route {
  Index
  Schematic(name: String)
  Pcb(name: String)
  Review(name: String)
  Library
  Account
  AuthLogin
  AuthRegister
  AuthManage
  OauthAuthorize
  NotFound
}

pub fn parse(uri: Uri) -> Route {
  let segments =
    uri.path
    |> string.split("/")
    |> list.filter(fn(s) { s != "" })

  case segments {
    ["v2"] -> Index
    ["v2", "schematics", name] -> Schematic(name)
    ["v2", "pcb", name] -> Pcb(name)
    ["v2", "review", name] -> Review(name)
    ["v2", "library"] -> Library
    ["v2", "account"] -> Account
    ["v2", "auth", "login"] -> AuthLogin
    ["v2", "auth", "register"] -> AuthRegister
    ["v2", "auth", "manage"] -> AuthManage
    ["v2", "oauth", "authorize"] -> OauthAuthorize
    _ -> NotFound
  }
}
