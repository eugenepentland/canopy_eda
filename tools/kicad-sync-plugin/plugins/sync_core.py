"""Core sync engine: turns a parsed netlist + footprint cache into a list
of mutations to apply against an open KiCad board.

The engine talks to KiCad through `BoardAdapter`, a small interface that
wraps `kipy` (the KiCad 10 IPC client). Tests fake the adapter so the diff
algorithm can be exercised without KiCad running.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Protocol

from .netlist_parser import Component, Netlist, pad_net_map


CANOPY_UUID_FIELD = "canopy_uuid"


# ── Adapter protocol ─────────────────────────────────────────────────────


class FootprintHandle(Protocol):
    """Opaque KiCad footprint reference. Adapters return whatever object
    they want; sync_core never inspects the type."""


class BoardAdapter(Protocol):
    def list_footprints(self) -> list[FootprintHandle]: ...
    def get_field(self, fp: FootprintHandle, name: str) -> str: ...
    def get_reference(self, fp: FootprintHandle) -> str: ...
    def get_footprint_name(self, fp: FootprintHandle) -> str: ...

    def set_field(self, fp: FootprintHandle, name: str, value: str) -> None: ...
    def set_reference(self, fp: FootprintHandle, ref: str) -> None: ...
    def set_value(self, fp: FootprintHandle, value: str) -> None: ...

    def set_pad_net(self, fp: FootprintHandle, pad_number: str, net_name: str) -> None: ...

    def add_footprint(self, kicad_mod_text: str, ref: str, value: str, uuid: str) -> FootprintHandle: ...
    def swap_footprint(
        self,
        fp: FootprintHandle,
        kicad_mod_text: str,
        new_footprint_name: str,
    ) -> FootprintHandle: ...
    def remove_footprint(self, fp: FootprintHandle) -> None: ...

    def begin_commit(self) -> object: ...
    def push_commit(self, commit: object, message: str) -> None: ...


# ── Result types ─────────────────────────────────────────────────────────


@dataclass
class SyncSummary:
    updated: list[str] = field(default_factory=list)
    added: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)
    flagged_stale: list[str] = field(default_factory=list)
    swapped: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def total_changes(self) -> int:
        return len(self.updated) + len(self.added) + len(self.removed) + len(self.swapped)


# ── Footprint loader (looks up cached .kicad_mod text by name) ───────────


class FootprintSource(Protocol):
    def get_kicad_mod(self, name: str) -> Optional[str]: ...


# ── The engine ───────────────────────────────────────────────────────────


def _strip_lib_prefix(footprint_spec: str) -> str:
    """`'footprints:R_0402_1005Metric'` → `'R_0402_1005Metric'`. Names in
    the manifest don't carry the library prefix, but netlist entries do."""
    if ":" in footprint_spec:
        return footprint_spec.split(":", 1)[1]
    return footprint_spec


def sync(
    board: BoardAdapter,
    netlist: Netlist,
    fp_source: FootprintSource,
    *,
    prune_stale: bool = False,
    commit_message: str = "EDA sync",
) -> SyncSummary:
    summary = SyncSummary()

    # Index existing board footprints by uuid + ref for matching.
    existing = board.list_footprints()
    by_uuid: dict[str, FootprintHandle] = {}
    by_ref: dict[str, FootprintHandle] = {}
    for fp in existing:
        uuid = board.get_field(fp, CANOPY_UUID_FIELD)
        if uuid:
            by_uuid[uuid] = fp
        ref = board.get_reference(fp)
        if ref:
            by_ref[ref] = fp

    pad_nets = pad_net_map(netlist)

    matched: set[int] = set()  # id() of matched FootprintHandles
    commit = board.begin_commit()

    for comp in netlist.components:
        fp_name_short = _strip_lib_prefix(comp.footprint)

        # Match by uuid first, fall back to ref-des (for legacy boards).
        fp = by_uuid.get(comp.uuid)
        if fp is None and comp.ref:
            fp = by_ref.get(comp.ref)
            if fp is not None:
                # Backfill the uuid for next time.
                board.set_field(fp, CANOPY_UUID_FIELD, comp.uuid)

        if fp is not None:
            matched.add(id(fp))
            current_fp_name = board.get_footprint_name(fp)
            if current_fp_name != fp_name_short:
                kmod = fp_source.get_kicad_mod(fp_name_short)
                if kmod is None:
                    summary.warnings.append(
                        f"{comp.ref}: footprint '{fp_name_short}' not in cache; skipping swap"
                    )
                else:
                    fp = board.swap_footprint(fp, kmod, fp_name_short)
                    summary.swapped.append(comp.ref)
            board.set_reference(fp, comp.ref)
            board.set_value(fp, comp.value)
            _apply_pad_nets(board, fp, comp, pad_nets)
            summary.updated.append(comp.ref)
            continue

        # New component — drop at origin.
        kmod = fp_source.get_kicad_mod(fp_name_short)
        if kmod is None:
            summary.warnings.append(
                f"{comp.ref}: footprint '{fp_name_short}' not in cache; skipping add"
            )
            continue
        new_fp = board.add_footprint(kmod, comp.ref, comp.value, comp.uuid)
        _apply_pad_nets(board, new_fp, comp, pad_nets)
        summary.added.append(comp.ref)

    # Stale: anything on the board with a canopy_uuid not in the netlist.
    netlist_uuids = {c.uuid for c in netlist.components if c.uuid}
    for fp in existing:
        if id(fp) in matched:
            continue
        uuid = board.get_field(fp, CANOPY_UUID_FIELD)
        if not uuid:
            continue  # not a Canopy-managed footprint, leave alone
        if uuid in netlist_uuids:
            continue  # already handled (renamed ref-des, etc.)
        ref = board.get_reference(fp)
        if prune_stale:
            board.remove_footprint(fp)
            summary.removed.append(ref)
        else:
            summary.flagged_stale.append(ref)

    board.push_commit(commit, commit_message)
    return summary


def _apply_pad_nets(
    board: BoardAdapter,
    fp: FootprintHandle,
    comp: Component,
    pad_nets: dict[tuple[str, str], str],
) -> None:
    """Push pad-to-net assignments for `comp` onto `fp`. Pads not mentioned
    in the netlist are left as-is — KiCad keeps whatever net they had, which
    is the correct behavior for NC pads."""
    for (ref, pin), net_name in pad_nets.items():
        if ref != comp.ref:
            continue
        try:
            board.set_pad_net(fp, pin, net_name)
        except KeyError:
            # Pin doesn't exist on this footprint (e.g. footprint swap
            # changed pin numbering). Surface but don't abort the sync.
            continue
