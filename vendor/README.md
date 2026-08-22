# Vendored Zig dependencies

These packages are committed because the application pins a Zig master
snapshot and must build without the network. Do not replace them with moving
branch URLs. Each nested `build.zig.zon` also pins the exact compiler minimum.

| Path | Upstream revision | Notes |
|---|---|---|
| `httpz` | `e6c23eb959e20bc8871184622fa9082ddaf5b106` (`dev`) | Includes deferred-signal, fd deregistration, shutdown-UAF, and timeout-sweep fixes. |
| `httpz/deps/metrics` | `21fe85eaa1761a870753a4d0b9e3f289986ac1a3` | Exact revision selected by httpz. |
| `httpz/deps/websocket` | `3318a78a2c3d3b972c394717c43a354d0feb8b91` (`dev`) | Exact revision selected by httpz. |
| `zt` | `a8b94373999c2483efa5f646438263785f70743d` (`main`) | Template compiler/runtime ported to the pinned snapshot. |

Ward owns and documents its separate vendored authentication/cryptography
stack (`passcay` and `zbor`) in the Ward repository.
