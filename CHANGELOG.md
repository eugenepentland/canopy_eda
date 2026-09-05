# Changelog

All notable changes to netlisp are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

netlisp was developed privately before this release. `0.1.0` is the first
public version, so there is no changelog history before it.

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-09-05

> **Clones made before 2026-09-05 must be re-cloned.** The history was
> rewritten before this release to remove the maintainer's private board
> designs, library and datasheets from every commit; commit ids changed.


First public release. netlisp is a command-line EDA tool for schematic capture
where the design is a set of `.sexp` text files rather than a drawing: one Zig
binary evaluates them into a schematic viewer, checks, a BOM, a PCB layout and
fabrication and KiCad outputs. There is no GUI capture step.

### What you get

- **A design language.** A small S-expression DSL: components, parameterised
  component families, modules with closures, nets inferred from pin
  connections, sections, assertions and formatting directives. The reference is
  `docs/sexp-language.md`, with the machine-generated `docs/language-forms.md`
  as its checked companion.
- **A schematic viewer.** `netlisp serve` renders a server-side HTML page with
  inline SVG (a hub-and-spoke schematic plus a system overview) and the design
  review panels, updating as the source changes.
- **Checks.** Electrical rule checks and requirement/assertion checks, with
  named profiles (`netlisp check --profile preflight`).
- **A BOM.** Component resolution with part numbers and properties carried
  through to every export.
- **PCB layout.** Placement, autorouting, copper pours and design-rule checks,
  editable in the browser and drivable from the CLI.
- **Fabrication output.** Gerber and drill packages, including panelization.
- **KiCad interop, both directions.** Export a netlist, footprints, STEP models
  and a complete hierarchical `.kicad_sch` project; push a board update into an
  existing `.kicad_pcb`; and import an existing KiCad board back into a netlisp
  design.
- **Documents.** PDF design-review exports and thermal FEM cases.
- **An agent-facing surface.** Every structured operation is a CLI tool with a
  JSON schema (`netlisp tool list`, `netlisp tool <name> --args '{…}'`), so
  the whole flow can be driven with no browser and no server.

### Added

- A **standard component library bundled into the binary**: the sixteen passive
  families (chip capacitors, resistors, inductors, ferrites and LEDs in 0201 to
  0805), their land patterns, and the generic board features a first board needs
  (test point, M2 mounting hole, 2.54 mm headers) with pinouts. A project with
  no `lib/` of its own now builds, checks and exports. A project's own `lib/`,
  then `--lib-dir` / `NETLISP_LIB_DIR`, then `NETLISP_STDLIB_DIR` override it
  per entry.
- `test/fixtures/stdlib-smoke`, a tracked, complete, library-less example
  project used by both the README quick start and the test suite.
- `scripts/install-zig.sh`, which downloads the pinned Zig snapshot and verifies
  it against the checked-in SHA-256 table, plus mirrored toolchain archives so
  the pin does not depend on Zig's rotating nightly directory.
- `serve --bind <addr>` to choose the listening interface, and
  `GET /healthz` as an unauthenticated liveness probe that reads no design.
- Host prerequisite checking (`scripts/check_host_prereqs.sh`) early in the
  build, naming whichever of Zig/Node/Python/git is missing.
- Project documentation for contributors: `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `SECURITY.md`, this changelog, and GitHub issue and
  pull-request templates.

### Changed

- **Authentication is now local-first, and the external `ward` dependency is
  gone.** A loopback request that did not pass through a proxy is an admin;
  everything else is refused with a `403` naming `--allow-remote`. The plugin
  bearer token still admits the KiCad board-sync route alone. The server binds
  `127.0.0.1` by default instead of every interface. See `docs/auth.md`.
- **Guardian is fetched by URL and hash** from a tagged release of
  `guardian-zig` instead of resolved through a sibling checkout, so a fresh
  clone builds with nothing beside it. The first build downloads the tarball
  once; every later build is offline.
- **One official Zig compiler.** The snapshot named in `.zigversion` is used for
  development, tests, release and deploy; `build.zig` refuses to configure on
  any other version, including a newer one. Optimized builds go through Zig's
  self-hosted backend by default, with `-Dllvm` as an opt-in escape hatch.
- The README was rewritten for someone arriving at a fresh clone:
  prerequisites, install script, quick start, the bundled library, the auth
  model, build modes and the agent-facing tool CLI.
- The tracked systemd unit no longer passes `--allow-remote`, so a fresh deploy
  fails closed rather than open. An operator publishing netlisp must opt in
  after putting an authenticating proxy in front.

### Removed

- The `ward` auth server dependency and everything behind it: session-cookie
  verification, OAuth bearer introspection, the RFC 9728 protected-resource
  document, `WARD_*` configuration, and the `NETLISP_DEV=1` loopback bypass
  (replaced by loopback being admin by default).
- Machine-specific and board-specific material that did not belong in a public
  tree: a single-host server runbook, personal root files, board-family
  documents and dead build scaffolding.

### Fixed

- Design saves are durable and source edits are bound to a revision, so two
  concurrent writers cannot silently lose one another's changes.
- Hierarchical autorouter seeds are preserved and recovered rather than
  discarded between runs.
- Autorouter cancellation, routing-experiment parity and saved-copper
  diagnostics.
- A failed component write during a package upload is now reported instead of
  being swallowed.

### Security

- The default posture is loopback-only with no way to reach the server from off
  the host, and the shipped deployment unit no longer disables that gate. See
  `SECURITY.md` for the threat model and how to report an issue privately.

[Unreleased]: https://github.com/eugenepentland/netlisp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/eugenepentland/netlisp/releases/tag/v0.1.0
