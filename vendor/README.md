# Vendored Zig dependencies

These packages are committed because the application pins a Zig master
snapshot and must build without the network. Do not replace them with moving
branch URLs. Each nested `build.zig.zon` also pins the exact compiler minimum.

| Path | Upstream revision | Licence | Notes |
|---|---|---|---|
| `httpz` | `e6c23eb959e20bc8871184622fa9082ddaf5b106` (`dev`) | MIT — [`httpz/LICENSE`](httpz/LICENSE) | Includes deferred-signal, fd deregistration, shutdown-UAF, and timeout-sweep fixes. |
| `httpz/deps/metrics` | `21fe85eaa1761a870753a4d0b9e3f289986ac1a3` | MIT — [`httpz/deps/metrics/LICENSE`](httpz/deps/metrics/LICENSE) | Exact revision selected by httpz. |
| `httpz/deps/websocket` | `3318a78a2c3d3b972c394717c43a354d0feb8b91` (`dev`) | MIT — [`httpz/deps/websocket/LICENSE`](httpz/deps/websocket/LICENSE) | Exact revision selected by httpz. The licence was missing from the trimmed vendoring and was restored from upstream at this revision. |

Every package here is modified: each was ported to the pinned Zig 0.17
snapshot, and the two `deps/` trees were trimmed of CI and packaging files.
Diff a vendored tree against
`https://codeload.github.com/<upstream>/tar.gz/<revision>` to see exactly
what changed. Vendoring a new package means committing its licence file in
the same commit and adding it to [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
