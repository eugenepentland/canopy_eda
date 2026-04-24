import gleam/javascript/promise.{type Promise}

pub type PixiApp

@external(javascript, "../../pixi_ffi.mjs", "mount_prototype")
pub fn mount_prototype(container_id: String, label: String) -> Promise(PixiApp)

@external(javascript, "../../pixi_ffi.mjs", "destroy")
pub fn destroy(app: PixiApp) -> Nil
