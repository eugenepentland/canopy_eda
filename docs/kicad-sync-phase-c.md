# KiCad Sync — Phase C: design-eval determinism

> Companion to [kicad-sync-architecture.md](kicad-sync-architecture.md).
> Phases A (diagnostics) and B (`applied_ops` sidecar suppression) are
> shipped. Phase C is the deeper fix the user originally asked for —
> "if I just re-sync, it says a footprint is updated and changes it to
> a different net" — and is deferred until somebody has time for
> surgery on the design evaluator.

## The symptom Phase B doesn't cover

Phase B suppresses re-emission of state-asserting ops whose
**fingerprint** (`uuid|op|key|value`) matches one the agent already
pushed last sync. It fixes the IPC-leak case — `set_locked`,
`set_field` writes that pcbnew accepts on disk but doesn't report back
on the next `GetItems`.

It does **not** fix the flip-flop case, where the same logical
component emits a `set_pad_net` / `set_field` with a **different
value** every sync. Two consecutive runs produce, e.g.:

```
sync 1: set_pad_net  uuid=abc…  pad=1  net=LEDK
sync 2: set_pad_net  uuid=abc…  pad=1  net=DISP_LEDK
sync 3: set_pad_net  uuid=abc…  pad=1  net=LEDK
…
```

The agent dutifully applies each op, KiCad moves the pad, the
footprint shifts to follow its new net's auto-routing, and the user
re-places it. Next sync repeats. The sidecar can't help: the value is
different each time, so the fingerprint never matches.

## Root cause: the design eval is non-deterministic across runs

The server's `/api/sync-plan` handler re-evaluates the `.sexp` source
on every request, then diffs the resulting `FlatInstance`s against the
board state the agent posted. The diff is stable; the **eval output is
not**. Two consecutive evals of an unchanged `.sexp` can produce
different `(ref_des → uuid → properties → pad_net)` assignments. Two
intertwined mechanisms drive this.

### Mechanism 1 — sub-block ref_des numbering is order-sensitive

`src/eval/ids.zig::assignSubBlockRefDes` (lines 122–175) walks each
sub-block's instance slice and calls `nextRefDes(prefix)` per
instance. `nextRefDes` (lines 23–28) is a per-prefix counter on
`Evaluator.auto_refdes`:

```zig
pub fn nextRefDes(self: *Evaluator, prefix: u8) EvalError![]const u8 {
    const gop = self.auto_refdes.getOrPut(self.allocator, prefix) catch …;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
    return std.fmt.allocPrint(…, "{c}{d}", .{ prefix, gop.value_ptr.* });
}
```

A counter-based scheme is fine **if the iteration order is stable**.
The instance slice is built during sub-block evaluation, and any of
the following pushes the order around between runs:

- A `defmodule` that returns instances in `let`/macro-expansion order
  rather than source order (the let-binding resolution sees the same
  inputs but the per-binding hash-map iteration is undefined).
- The order modules are evaluated in (the `sub_blocks` slice itself is
  in source order, but each sub-block's *internal* instance order
  comes from `evalDesignBlock`'s eval loop, which depends on builder
  call order).
- Anywhere we walk a `std.StringHashMap` and rely on the iteration
  order — those orders are unspecified and can shift on re-allocations.

When the order shifts, the same logical instance gets `C5` on run 1
and `C7` on run 2. Because the BOM sidecar is keyed by `ref_des`, the
next sync's `bom_resolve` Pass 0/1 look-up follows the *new* ref_des,
finds a *different* old entry, and copies the wrong uuid + properties
forward.

### Mechanism 2 — `bom_resolve` Pass 3.5 is not idempotent

`src/bom_resolve.zig::resolveIdentities` lines 205–251 ("Pass 3.5:
correct UUID assignments by net matching") tries to repair Mechanism
1's damage by swapping two ref_des' uuids when their assigned uuids
don't match their pad-net signatures. The swap looks like:

```zig
result_map.putAssumeCapacity(info.ref_des, …correct_uuid…);
result_map.putAssumeCapacity(oref,         …assigned_uuid…);
```

The pass is meant to be a self-healing nudge, but two properties make
it pathological under Mechanism 1:

1. **Order-dependent.** It iterates `flat_list.items` and operates on
   the *current* `result_map` state. Swap A↔B is applied; later in
   the same pass, swap B↔C may also fire because B's nets now belong
   to C. The pass can produce different terminal states depending on
   visit order.
2. **Not a fixed point.** The BOM is rewritten with the post-swap
   uuids. On the next eval, ref_des may have shifted again
   (Mechanism 1), so the same Pass 3.5 logic re-fires — sometimes
   re-swapping back, sometimes not. Hence the ping-pong.

The net effect is that **two ref_des trade their uuids back and
forth** across consecutive syncs, the diff sees a uuid that "moved"
between two footprints, and `set_pad_net` / `set_field` emits with
mirror-image values each time.

## Why this is hard to fix in isolation

Each mechanism has a tempting one-line fix that doesn't hold up:

- **"Just sort instances by source-line offset before
  `nextRefDes`."** Works only if every instance carries a span back
  to a unique source location. `(defmodule …)` instances do, but
  instances synthesised by builders (`(decouple …)`, `(series …)`,
  rail expansions) point at the *call site* of the builder — multiple
  synthesised instances share a span. Need a secondary tiebreaker
  (insertion order, label) and that tiebreaker has to itself be
  stable across the upstream changes.
- **"Just remove Pass 3.5."** It exists for a reason: when a
  designer renames a sub-block or adds an instance, Pass 0–3 can
  legitimately assign uuids the wrong way around (Pass 2 picks
  "the sole instance of this component" without looking at nets).
  Deleting it regresses the rename-detection story. The pass needs
  to *converge*, not vanish.
- **"Stop writing the BOM back to disk."** Tried during Phase B
  triage and reverted (commit conversation in session log). The BOM
  is the only thing stabilising ids across runs for instances that
  go through Pass 1/2 (no `(id …)` in the source). Without
  writeback, every fresh eval re-derives ids and the cascade gets
  worse.

The fix has to land on both fronts at once, with a verification path
that proves convergence (two consecutive evals of the same source
produce byte-identical `flat_list.items`).

## Proposed fix — split into two reviewable commits

### Commit C.1 — make ref_des assignment a deterministic function of source

Files: `src/eval/ids.zig`, possibly `src/eval/design_block.zig`.

Concrete steps:

1. Audit every iteration point inside `assignSubBlockRefDes`,
   `autoAssignSubBlockRefDes`, and `autoAssignRefDes` for hash-map
   order dependencies. Replace with explicit sorts where any are
   found.
2. Before per-prefix counters increment, build a *deterministic
   ordering* of all instances that will get auto-numbered. Sort key:
   `(sub_block_path, source_span.offset, label)`. Source span
   alone is not enough — builder-synthesised instances share spans.
3. Add a regression test: evaluate a known design twice in the same
   process, compare the full `flat_list` (ref_des, id, uuid,
   properties, pad nets). Must be byte-identical. Today's test suite
   doesn't catch this because each test does a single eval.
4. Run the agent twice on the Cyclops board (the same diagnostic
   from Phase A) and confirm the second run's plan is empty.

What this *doesn't* yet fix: legacy boards whose existing BOM was
written under non-deterministic ref_des — first run after C.1 still
shifts ids around. That's expected and one-shot; the post-shift BOM
is stable.

### Commit C.2 — make Pass 3.5 a fixed point

Files: `src/bom_resolve.zig`.

Concrete steps:

1. Restructure Pass 3.5 to **collect all proposed swaps first**,
   then apply them in one pass after detecting cycles. A swap A↔B
   plus a swap B↔C is suspicious — it means net signatures don't
   bijectively partition the candidate set. Log and skip the
   ambiguous cluster rather than firing a partial chain.
2. After applying swaps, re-run the net-signature check. If any
   instance still has a mismatched uuid, log a warning — the eval
   has produced inputs Pass 3.5 can't reconcile, and a re-sync will
   just re-fire the same swap. Failing loud beats silent flip-flop.
3. Add a test: construct a `DesignBlock` + BOM combination that
   currently triggers a swap, run `resolveIdentities` twice, assert
   the second call is a no-op.

### Commit C.3 (optional) — kill the BOM round-trip dependency

The cleanest long-term fix is to **stop keying carryforward by
ref_des at all** and key it by `(id …)` only. Drop Pass 1 (exact
ref_des match) and Pass 2 (sole-of-component rename detection)
entirely. Any instance without an `(id …)` would get a fresh
deterministic id derived from `(sub_block_path, label)` — the same
function `reassignSubBlockIds` already uses. The BOM becomes a pure
properties cache, not an identity authority.

Out of scope for the immediate flip-flop fix because it changes
behaviour for designs that have been hand-edited without ids. Worth
revisiting once C.1 + C.2 are stable in the field.

## Verification

End-to-end test on the Cyclops board (same script as Phase A
diagnostics):

```bash
cp "<board>.kicad_pcb" "<board>.kicad_pcb.phase-c-before.bak"
eda-kicad-sync --board "<board>.kicad_pcb"           # sync 1: applies real diff
cp /tmp/eda-kicad-sync.log /tmp/phase-c-sync1.log
eda-kicad-sync --board "<board>.kicad_pcb" --dry-run # sync 2: expect zero ops
eda-kicad-sync --board "<board>.kicad_pcb" --dry-run # sync 3: expect zero ops
```

Pass criteria — sync 2 and sync 3 both report:

```
Already up to date @ v<N>
```

(not "Already up to date … suppressed N"). Suppression is Phase B
papering over the bug; Phase C eliminates the bug. Then re-check
disk-level idempotency:

```bash
diff <board>.kicad_pcb <board>.kicad_pcb.phase-c-before.bak
```

After sync 1's expected changes, sync 2 and 3 should produce zero
new disk diff.

## What lives where

- `src/eval/ids.zig` — `nextRefDes` (23), `assignSubBlockRefDes`
  (122), `autoAssignSubBlockRefDes` (116), `reassignSubBlockIds`
  (295). Mechanism 1 lives here.
- `src/eval/design_block.zig:148–151` — the call sequence
  (`autoAssignRefDes` → `autoAssignSubBlockRefDes`) that turns
  source labels into global ref_des.
- `src/eval/builders.zig:661` — `reassignSubBlockIds` invocation
  inside `buildSubBlock`. The "module-local label" referenced in the
  comment is the stable input we want to lean on harder in C.3.
- `src/bom_resolve.zig:205–251` — Pass 3.5. Mechanism 2 lives here.
- `src/bom_resolve.zig:191–203` — Pass 3, the id→uuid derivation
  that already gives us a deterministic uuid *if* the id is stable.
- `tools/kicad-sync-go/internal/sync/sync.go` — already reads
  `<board>.applied_ops.json`; Phase C makes that read mostly
  unnecessary, but the sidecar stays as defence in depth against
  future KiCad-IPC leaks.

## Why this is filed instead of fixed

The fix changes `bom_resolve` and `ids.zig` behaviour for every
design in the repo, not just Cyclops. The risk surface is large
(rename detection, sub-block id stability, ERC's dependency on
stable ref_des for "duplicate ref_des" checks). It needs a clear
diagnostic loop ("eval twice, diff outputs") that doesn't exist
yet, plus a fixture design that exercises the flip-flop in a unit
test rather than only on the live Cyclops board.

Phase B is the right place to stop for now: the IPC-leak class is
fixed, the user has a `Suppressed: N` indicator that surfaces the
remaining flip-flop without it costing footprint placements, and
the Cyclops board is unblocked. Phase C is the follow-up that
removes the suppression entirely.
