# Barracuda PCB-editor zoom gate

This gate opens the real `/pcb-layout/barracuda-base` page and drives the
viewer’s deterministic `fbench=zoom` camera program. Each step changes the
camera once and lets the queued scene paint complete before the next sample, so
wheel-event coalescing cannot turn expensive paints into an apparently smooth
result. The profile zooms from fit to 8× and back out.

Two profiles cover different failure modes:

- Canvas2D runs at 1600×900 and DPR 2. It is the high-density fallback when
  WebGPU is unavailable and carries the strict user-facing latency budgets.
- WebGPU runs at DPR 1 through Chromium’s pinned SwiftShader Vulkan device. It
  must remain active while rendering at least 50 swept RF paths, 1,000 tracks,
  and 500 vias. Its wider software-raster budgets bound command-stream growth;
  they are not a claim about hardware-GPU frame rate.

The release candidate gate runs this benchmark after the exact production
binary has passed tests, been built ReleaseSafe, and been stripped. A candidate
without `pcb_editor_perf=passed` metadata cannot be adopted or deployed. The
main pre-push performance suite also runs it alongside the server-page,
Assembly, and all-pages browser gates.

Build a production-class binary and run the focused gate with:

```sh
scripts/zig-prod build --seed=1 -Doptimize=safe -p zig-out-browser-perf
npm run perf:pcb-editor -- --binary zig-out-browser-perf/bin/netlisp \
  --project-dir projects/designs
```

Use `--url http://127.0.0.1:PORT` for a read-only diagnostic run against an
existing loopback dev server. Use `--record` only when deliberately replacing
the reference measurements; it preserves existing reviewed budgets.
