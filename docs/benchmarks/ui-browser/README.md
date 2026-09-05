# All-pages browser performance gate

`scripts/ui_browser_perf/run.js` opens every interactive Netlisp page in real
headless Chromium and performs the ordinary operations a person uses there.
It complements the server-side `bench-page` gate and the deeper exact-CAM
assembly benchmark; it does not replace either one.

The registry currently covers 71 real-browser interactions across the home page, board and standalone-module
schematics, PCB 2D and 3D, thermal review, library browsing, footprint editing,
3D model alignment, autoroute review, and the PDF viewer. It also checks the
raw datasheet response and both retired-route redirects. Assembly is declared
as delegated coverage because `scripts/pcb_browser_perf/run.js` already drives
its exact manufactured-board iframe with a stricter 90-frame gesture workload,
the ordinary search/filter/BOM/panel/CAM/orientation controls, and safe 3D-page
navigation.

The PCB 2D surface includes saved-layout navigation and a successful Update in
the runner's private project overlay, DRC next/previous navigation, trace-head preview and Escape-style
cancellation with an unchanged-copper oracle, standalone-via placement and
undo, copper-area arm/cancel, server-computed pour refill, direct zoom controls,
component drag/undo, pan, search, panels, and appearance. Trace coverage stops
at the live routed preview before cancellation; it deliberately does not commit
a trace into the shared design workload.

For each surface the runner records app-ready navigation latency, long tasks,
local and asynchronous control latency, and real pointer/wheel frame cadence.
Pan, orbit, zoom, component drag, and pad drag are sent through Playwright's
mouse input rather than by calling private renderer functions. Every gesture
must also change rendered or camera state, so a removed event handler cannot
pass by producing perfect no-op frames. The route-review scenario uploads a
tracked 20-part, eight-crossed-net KiCad workload with keepouts and runs the
real in-memory router.

The home surface also waits for every board's asynchronous layout-progress
card to finish hydrating. That action intentionally runs last: besides covering
the progress UI, it prevents a closed repetition from leaving placement work
on the server that could starve the next page's static assets. Its 25-second
budget covers the deliberate cold background fill of the dependency-validated
progress cache (the poured `barracuda-base` board is the dominant input);
normal production startup precomputes that cache before serving pages.

## Safety and hermeticity

Each repetition gets a fresh browser context at 1600×900 and DPR 1. The
self-started runner copies/reflinks `src`, history, and writable model metadata
into an owned temporary project, then allows only the exact PCB-layout and
model-transform POSTs while their two save scenarios are active. It restores
those files between repetitions and restores the original model transform
through the private endpoint outside the timed interval. An existing-server
`--url` run never gets that permission and measures the blocked failure feedback
without writing to the target. The context blocks every other write and all
cross-origin requests except the explicitly read-only route-review and PCB DRC
computations; schematic PCB-sync probes are allowed only with `dry_run=1`. An
unexpected write, external dependency, JavaScript exception, or required
first-party request failure fails the run.

PDF.js, its worker, Three.js, and the test PDF are all served locally. The PDF
fixture is generated in-repo from copyright-clean synthetic content and carries
four pages of dense text, tables, vector graphics, and distinct embedded images;
regenerate it with `node test/fixtures/browser_perf/generate_datasheet.js`.
No MCP server, Windows desktop, display server, or internet access is involved.
The complete `scripts/perf_gate.sh` path also expands the designs repository's
committed `HEAD` into a temporary snapshot. Ignored vendor STEP files, saved
layout sidecars, and generated BOM sidecars are copied into that disposable
tree and included in its content fingerprint; generated model sprites start
empty and remain in the snapshot if a page creates them. Dirty tracked library
edits therefore cannot skew a commit gate, the gate cannot mutate the live
design library, and any model, layout, BOM, or committed workload change
requires a deliberate re-record.

## Run it on headless Ubuntu

Install the pinned JavaScript dependencies once:

```sh
npm ci
npx playwright install --with-deps chromium
```

Use Node 20 or newer for this harness. Playwright's supported Node runner is
the stable compatibility choice; Bun or Deno would not make these measurements
meaningfully faster because Chromium rendering and the Zig server dominate the
run, not JavaScript process startup.

Then build the production-class server and run either the full performance
gate or only the UI matrix:

```sh
zig build --seed=1 -Doptimize=safe -p zig-out-browser-perf
npm run perf:ui -- --binary zig-out-browser-perf/bin/netlisp
scripts/perf_gate.sh
```

Useful focused commands:

```sh
npm run perf:ui -- --list
npm run perf:ui -- --surface pcb_2d --reps 5
npm run perf:ui -- --scenario pcb_2d.find --reps 10
```

Every measuring invocation (focused ones included) queues itself under
`scripts/gate.sh`'s machine-wide lock via `scripts/perf_gate_lock.js`, the
same lock `scripts/perf_gate.sh` holds for the full matrix — timing runs
outside the queue corrupt whatever gated run they overlap (FEEDBACK.md
2026-08-29). `--list` and argument validation stay lock-free. gate.sh reports
the queue depth when it has to wait; `NETLISP_GATE_SERIALIZE=0` bypasses the
queue on a machine known idle.

`--url http://127.0.0.1:PORT` uses an already-running private loopback server
for focused surface/action runs and therefore requires `--surface` or
`--scenario`. It cannot be combined with `--record`; raw-response checks and
baseline recording remain complete self-started runs, where the tracked PDF is
present. Non-loopback URLs are refused. Without `--url`, the runner starts and
stops its own random-port loopback server with `--skip-warmup`.

## Coverage and baselines

`manifest.test.js` parses every non-API GET registration in `src/serve.zig`.
It fails unless each route is tied to a runnable surface, the dedicated
assembly runner, a response/redirect check, or an explicit non-page
classification. It also requires the manifest's normal interactions and the
runner's action table to match exactly. The desktop PCB toolstrip has an exact
source-derived control inventory: adding or renaming a primary button fails the
contract until it receives a scenario or a concrete reviewed exclusion. Primary
layout, DRC, pour, find, and undo controls outside that strip are also pinned to
their source IDs and scenarios.

`baseline.json` contains reference measurements plus reviewed absolute
budgets. `--record` runs the complete matrix, preserves existing budgets, and
atomically replaces only the reference. Review that diff before committing;
do not loosen a budget merely to make a noisy or contended run green. The
browser and viewport are pinned, but results remain same-machine regression
measurements rather than claims about a Windows client's GPU.
