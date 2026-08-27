# Assembly browser performance gate

This gate runs the real `/assembly-debug/barracuda-base` page in headless
Chromium on Linux. Its `fbench=quick` page query makes the initial PCB iframe
open with `fbench=quick&gpu=1`; it then waits for the deferred generated-Gerber
CAM payload and measures the same `setVB`/`zoomAt` camera path used by drag and
wheel input.
It separately gates the time from iframe navigation until that exact CAM
payload has been parsed and installed, so a fast pan cannot hide a slow-open
regression.
Startup work is also subject to reviewed long-task caps: no single task may
exceed 250 ms and the median run may spend at most 750 ms in long tasks.
The shell portion gates search and type/DNP filtering, BOM selection and clear,
panel navigation, exact-CAM layer visibility, board side and rotation, and the
3D-view navigation link. Each interaction waits for and asserts its semantic or
rendered state change; it cannot pass as a fast no-op. `barracuda-base` has no
rework-guide fixture, so its panel-navigation case opens and closes the Layers
panel. When a guide-bearing design is selected manually, the same case opens
the Guide panel and its first guide before returning to Parts.

The “3D models” checkbox is inventoried but deliberately excluded from this
read-only gate: a cold checkbox run creates missing persistent sprite PNGs via
POST. Instead, the benchmark middle-clicks the ordinary 3D navigation link,
gates the usable base-board view, drains the complete STEP scene, and closes the
auxiliary tab without aborting its model reads. The request guard continues to
reject every browser write.
The quick profile uses 30 frames per sweep (90 pan frames total) at the same
per-frame distance as the manual `fbench=1` profile's longer 120-frame sweeps.
It does not use Chrome DevTools MCP or require the Windows desktop client.

## One-time Ubuntu setup

Install Node 20 or newer, then from the repository root run:

```sh
npm ci
npx playwright install --with-deps chromium
```

`--with-deps` needs sudo for missing Ubuntu browser libraries. A host whose
administrator supplies those packages can instead run `npx playwright install
chromium`. The benchmark also recognizes a rootless library bundle at
`~/.local/lib/playwright-chromium/usr/lib/x86_64-linux-gnu`.

## Running it

Build the production-class ReleaseSafe benchmark binary once, then run the gate. It starts and stops its own
random-port `NETLISP_DEV=1` loopback server, so no deployed server, login, or
MCP service is involved. It also passes `--skip-warmup`; otherwise the server's
unrelated whole-corpus cache warm-up competes with the measured page.

```sh
scripts/zig-prod build --seed=1 -Doptimize=safe -p zig-out-browser-perf
npm run perf:assembly -- --binary zig-out-browser-perf/bin/netlisp
```

Use `npm run perf:assembly -- --record` only when deliberately replacing the
reference measurements. Existing reviewed budgets are preserved. The normal
pre-push performance gate runs this benchmark after the server-side page gate.

`--url http://127.0.0.1:PORT` can target an already-running private loopback
server for diagnosis; non-loopback URLs are refused and existing-server runs
cannot record a baseline. In either mode the browser
context blocks cross-origin traffic and every non-read-only request, and the run
fails on an external dependency, attempted write, or unexpected first-party
HTTP/request failure. Normal same-origin GET, HEAD, and OPTIONS traffic remains
available to the assembly page and its PCB iframe.

The committed budgets are machine gates, not universal claims about the
Windows client's GPU or display. Linux runs WebGPU through Chromium's bundled
SwiftShader Vulkan ICD so the exact CAM path is deterministic even on a
headless host. A slow Windows interaction can still be profiled by opening the
same `?fbench=1&gpu=1` iframe there and reading the on-screen result.
