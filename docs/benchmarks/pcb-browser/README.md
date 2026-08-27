# Assembly browser performance gate

This gate runs the real `/assembly-debug/barracuda-base` page in headless
Chromium on Linux. It rewrites only the page's PCB iframe request to add
`fbench=quick&gpu=0`, waits for the deferred generated-Gerber CAM payload, then
measures the same `setVB`/`zoomAt` camera path used by drag and wheel input.
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

The committed budgets are machine gates, not universal claims about the
Windows client's GPU or display. A slow Windows interaction can still be
profiled by opening the same `?fbench=1&gpu=0` iframe there and reading the
on-screen result; Linux CI's job is to catch code regressions reproducibly.
