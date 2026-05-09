# KiCad Sync — agent architecture

Design contract for the Canopy EDA → KiCad PCB sync pipeline. The goal
is a **thin, infrequently-updated Go agent** that pushes one binary
across every user's machine and a **smart server** that owns all the
EDA-specific logic. Updating the agent should be a rare event tied to
KiCad's IPC protocol changing, not to schematic features evolving.

## Components

```
┌─────────────────┐    HTTPS+OAuth    ┌────────────────────┐
│  EDA server     │◄─────────────────►│ User's PC          │
│  /api/sync-plan │   sync-plan body  │  ┌──────────────┐  │
│  (Zig)          │   ─────────────►  │  │ eda-kicad-   │  │
│                 │   ops list        │  │ sync (Go)    │  │
│  diff algorithm │   ◄────────────   │  └──────┬───────┘  │
│                 │                   │         │ NNG IPC  │
│                 │                   │  ┌──────▼───────┐  │
│                 │                   │  │ KiCad 10     │  │
└─────────────────┘                   │  └──────────────┘  │
                                      └────────────────────┘
```

### Server is the brain

- Knows the design (`.sexp` source, BOM, properties).
- Knows the diff (which design properties differ from the board).
- Decides which ops to emit.
- Owns the canonical-name map (`mpn → MPN`, …).
- Loads footprint geometry from `lib/footprints/*.sexp`.

### Agent is the relay

- Reads board state from KiCad over IPC.
- Posts the full state to the server.
- Applies the returned ops in one IPC commit.
- Tracks no design state, no library, no protocol semantics beyond
  "decode this op, call this IPC method."

## What's wire-stable (rarely changes)

These are the contracts the agent and server share. Changing any of
these is a synchronised release across both sides.

### Op types

| op              | agent-side method                    |
|-----------------|--------------------------------------|
| `set_field`     | `SetField(uuid, field, value)`       |
| `set_pad_net`   | `SetPadNet(uuid, padNumber, netName)`|
| `add`           | `AddFootprint(def, uuid, ref, …)`    |
| `swap_footprint`| `SwapFootprint(uuid, def, padNets)`  |
| `remove`        | `Remove(uuid)`                       |
| `flag_stale`    | (no-op; informational)               |

New op types require an agent update. Adding ops is rare — the
existing six cover every footprint mutation we've needed.

### Board state shape (`BoardFp`)

```
{
  uuid:           canopy_uuid custom field on the footprint
  kicad_uuid:     KiCad-internal handle (always present)
  ref:            reference designator
  value:          KiCad value field
  footprint_name: library footprint name
  fields:         map<string,string> of every custom Field on the fp
  pads:           [{number, net}]
}
```

The `fields` map is the **escape hatch** that keeps the agent thin:
the server can diff arbitrary design properties against the map
without the agent ever knowing which fields exist. Adding a new BOM
column (supplier_pn, lifecycle, revision, …) is a pure server-side
change — the agent already reads every Field item on the footprint
into the map and ships it.

## How footprint geometry travels

Server emits proto-canonical JSON for `kiapi.board.types.Footprint`
messages — camelCase field names, string enum values, Any-wrapped
items with `@type: type.googleapis.com/kiapi.board.types.Pad`. The
agent decodes via `protojson.Unmarshal` into `*board_types.Footprint`
with no schema-aware code on the client. New pad shapes / types /
layers / drill features are server-only changes; the agent inherits
them for free as long as the generated `.pb.go` files match KiCad's
proto schema.

Per-instance pad-net assignments don't travel inside the geometry
JSON (it's shared across every instance of a footprint name). They
ride alongside in `op.PadNets` and are stamped onto the decoded Pad
messages by `stampPadNets` in the agent — a tiny bit of glue that
wraps `protojson.Unmarshal`.

The two places the server still hand-rolls the JSON shape are
`writePadProtoJson` (pad geometry) and `loadFootprintDef` (the
Footprint wrapper) in `src/serve/sync.zig`. Adding a new field to
either is a one-line server change — tables for pad-type and
pad-shape enum names live next to those writers.

## When the agent *does* need an update

Only these classes of change require shipping a new binary:

1. **KiCad bumps the IPC protocol** — generated `.pb.go` files
   regenerate, and any RPC-shape changes (new method, renamed message)
   land in the agent.
2. **A new op type lands in the wire protocol** — see the table above.
3. **A new pad geometry feature** — *until* the proto-canonical
   migration above lands; after that it's purely server-side.
4. **A new auth flow on the server** — the agent's `internal/oauth`
   has the OAuth client, would change with major auth changes.

What does **not** require an agent update:

- Adding a BOM property (manufacturer, datasheet, supplier_pn, …) —
  shipped as part of the [Fields-map refactor][fields-map].
- Renaming or deleting a property — server-side decision.
- Changing the canonical-name map.
- Changing the diff algorithm (matching tiers, prune semantics, etc.).
- Adding new design-side validation.
- Adding new schematic features that don't change the IPC shape.

[fields-map]: ../tools/kicad-sync-go/internal/eda/client.go

## File map

Server (Zig) — owns everything domain-specific:

- `src/serve/sync.zig` — `/api/sync-plan/:name` handler, diff loop,
  op emission, BoardFp parsing.
- `src/eval/`, `src/bom.zig` — design evaluation produces
  `FlatInstance`s with `.properties` for the diff loop.
- `src/export_kicad_footprint.zig` — converts `lib/footprints/*.sexp`
  into the wire footprint definition (the only KiCad-format-aware
  module on the server).

Agent (Go) — owns IPC plumbing only:

- `cmd/eda-kicad-sync/main.go` — CLI entry, mode dispatch.
- `internal/sync/` — orchestrator: list footprints → POST → apply ops.
- `internal/eda/` — HTTP client + wire types.
- `internal/kicad/iface.go` — `Client` interface, the small surface
  the orchestrator depends on.
- `internal/kicad/client.go` — real IPC implementation; the only file
  that touches NNG + protobuf. `decodeFootprintDef` is the entire
  geometry surface (calls `protojson.Unmarshal`); `stampPadNets`
  threads per-instance net assignments onto the decoded pads.
- `internal/kicad/fake.go` — in-process fake for tests.

## Versioning

The agent is shipped via `go install …@latest`; users pull a new
version manually. The agent and server are compatible across protocol
versions as long as:

- The server emits ops the agent recognises (new op types are the
  one breaking change).
- The wire shape's well-known fields haven't changed name. New
  optional fields (`omitempty` on the agent side, `if (field)` checks
  on the server) are added freely.

When a breaking change lands, bump the OAuth client scope so old
agents fail-closed at the auth layer rather than misinterpreting ops.
