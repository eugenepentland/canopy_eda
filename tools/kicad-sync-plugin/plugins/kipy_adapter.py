"""BoardAdapter implementation backed by `kipy` (the KiCad 10 IPC client).

`kipy` is imported lazily so the rest of the package — parser, HTTP client,
OAuth, sync_core — stays importable in environments without KiCad. This
module is the single place that depends on the IPC API shape, so when kipy
revs an API we only edit one file.

Targets kipy 0.4+. Method names below correspond to the protobuf-backed
Python bindings exposed by KiCad 10's IPC service.
"""

from __future__ import annotations

from typing import Any, Optional

# Imported lazily inside __init__ to avoid hard-failing at module load time
# when the plugin is being inspected by tooling without kipy installed.
_kipy: Any = None
_kipy_board_mod: Any = None
_kipy_geometry_mod: Any = None


def _import_kipy() -> None:
    global _kipy, _kipy_board_mod, _kipy_geometry_mod
    if _kipy is not None:
        return
    import kipy  # noqa: WPS433 (intentional lazy import)
    from kipy import board as kipy_board  # type: ignore
    from kipy import geometry as kipy_geometry  # type: ignore

    _kipy = kipy
    _kipy_board_mod = kipy_board
    _kipy_geometry_mod = kipy_geometry


class KipyBoardAdapter:
    """Adapter implementing the `BoardAdapter` protocol from sync_core.

    Holds a `Board` handle from kipy plus a write-buffer of footprints we've
    mutated; we batch-flush on push_commit so KiCad sees a single commit in
    its undo stack.
    """

    def __init__(self) -> None:
        _import_kipy()
        self._kicad = _kipy.KiCad()
        self._board = self._kicad.get_board()
        if self._board is None:
            raise RuntimeError("No PCB is open in KiCad. Open a .kicad_pcb first.")
        self._dirty: list[Any] = []
        self._added: list[Any] = []
        self._removed: list[Any] = []

    # ── Read ────────────────────────────────────────────────────────────

    def list_footprints(self) -> list[Any]:
        return list(self._board.get_footprints())

    def get_field(self, fp: Any, name: str) -> str:
        # kipy exposes custom fields as a dict-like on Footprint. Fall back
        # to scanning .text_items / .fields if .field() isn't present.
        getter = getattr(fp, "field", None)
        if callable(getter):
            try:
                f = getter(name)
                return f.text if f is not None else ""
            except Exception:
                pass
        fields = getattr(fp, "fields", None)
        if fields is not None:
            try:
                f = fields.get(name)
                return getattr(f, "text", "") if f is not None else ""
            except Exception:
                return ""
        return ""

    def get_reference(self, fp: Any) -> str:
        ref = getattr(fp, "reference", None)
        if isinstance(ref, str):
            return ref
        return getattr(ref, "text", "") if ref is not None else ""

    def get_footprint_name(self, fp: Any) -> str:
        # Footprint identifier in the form "lib:name"; we want just "name".
        ident = getattr(fp, "library_link", None) or getattr(fp, "footprint_name", None) or ""
        if isinstance(ident, str) and ":" in ident:
            return ident.split(":", 1)[1]
        return ident or ""

    # ── Write ───────────────────────────────────────────────────────────

    def set_field(self, fp: Any, name: str, value: str) -> None:
        setter = getattr(fp, "set_field", None)
        if callable(setter):
            setter(name, value, hidden=True)
        else:
            # Older API: mutate the dict on the Footprint object.
            fields = getattr(fp, "fields", None)
            if fields is None:
                raise RuntimeError("kipy Footprint exposes neither set_field nor .fields")
            fields[name] = value
        self._dirty.append(fp)

    def set_reference(self, fp: Any, ref: str) -> None:
        if hasattr(fp, "reference") and not isinstance(fp.reference, str):
            fp.reference.text = ref
        else:
            fp.reference = ref
        self._dirty.append(fp)

    def set_value(self, fp: Any, value: str) -> None:
        if hasattr(fp, "value") and not isinstance(getattr(fp, "value", None), str):
            fp.value.text = value
        else:
            fp.value = value
        self._dirty.append(fp)

    def set_pad_net(self, fp: Any, pad_number: str, net_name: str) -> None:
        pad = self._find_pad(fp, pad_number)
        if pad is None:
            raise KeyError(pad_number)
        net = self._board.get_net_by_name(net_name) if hasattr(self._board, "get_net_by_name") else None
        if net is None:
            net = self._board.create_net(net_name) if hasattr(self._board, "create_net") else None
        if net is None:
            raise RuntimeError(f"unable to resolve or create net '{net_name}'")
        pad.net = net
        self._dirty.append(fp)

    def add_footprint(self, kicad_mod_text: str, ref: str, value: str, uuid: str) -> Any:
        fp = self._load_footprint(kicad_mod_text)
        # New footprints drop at the origin; user is responsible for placement.
        origin = _kipy_geometry_mod.Vector2(0, 0) if hasattr(_kipy_geometry_mod, "Vector2") else (0, 0)
        if hasattr(fp, "position"):
            try:
                fp.position = origin
            except Exception:
                pass
        self.set_reference(fp, ref)
        self.set_value(fp, value)
        self.set_field(fp, "canopy_uuid", uuid)
        self._added.append(fp)
        return fp

    def swap_footprint(self, fp: Any, kicad_mod_text: str, new_footprint_name: str) -> Any:
        new_fp = self._load_footprint(kicad_mod_text)
        # Preserve placement.
        for attr in ("position", "orientation", "layer"):
            if hasattr(fp, attr) and hasattr(new_fp, attr):
                try:
                    setattr(new_fp, attr, getattr(fp, attr))
                except Exception:
                    pass
        # Carry over canopy_uuid + reference + value.
        self.set_field(new_fp, "canopy_uuid", self.get_field(fp, "canopy_uuid"))
        self.set_reference(new_fp, self.get_reference(fp))
        old_value_attr = getattr(fp, "value", None)
        old_value = old_value_attr if isinstance(old_value_attr, str) else getattr(old_value_attr, "text", "")
        self.set_value(new_fp, old_value)
        # Carry over pad nets where pad numbers match.
        old_pads_by_num: dict[str, Any] = {p.number: p for p in self._iter_pads(fp)}
        for pad in self._iter_pads(new_fp):
            old = old_pads_by_num.get(pad.number)
            if old is not None and getattr(old, "net", None) is not None:
                pad.net = old.net
        self._added.append(new_fp)
        self._removed.append(fp)
        return new_fp

    def remove_footprint(self, fp: Any) -> None:
        self._removed.append(fp)

    # ── Commit ──────────────────────────────────────────────────────────

    def begin_commit(self) -> Any:
        # Some kipy versions expose explicit begin/push; others auto-batch.
        begin = getattr(self._board, "begin_commit", None)
        if callable(begin):
            return begin()
        return None

    def push_commit(self, commit: Any, message: str) -> None:
        # Apply buffered mutations in one batch.
        if self._added and hasattr(self._board, "create_items"):
            self._board.create_items(self._added)
        if self._dirty and hasattr(self._board, "update_items"):
            # De-dup by id() — a single fp can be touched many times during sync.
            seen: set[int] = set()
            unique_dirty = []
            for fp in self._dirty:
                if id(fp) in seen:
                    continue
                seen.add(id(fp))
                unique_dirty.append(fp)
            self._board.update_items(unique_dirty)
        if self._removed and hasattr(self._board, "remove_items"):
            self._board.remove_items(self._removed)

        push = getattr(self._board, "push_commit", None)
        if callable(push):
            push(commit, message)

        self._added.clear()
        self._dirty.clear()
        self._removed.clear()

    # ── helpers ─────────────────────────────────────────────────────────

    def _find_pad(self, fp: Any, number: str) -> Optional[Any]:
        for pad in self._iter_pads(fp):
            if str(pad.number) == str(number):
                return pad
        return None

    @staticmethod
    def _iter_pads(fp: Any):
        pads_attr = getattr(fp, "pads", None)
        if pads_attr is None:
            return []
        return list(pads_attr() if callable(pads_attr) else pads_attr)

    def _load_footprint(self, kicad_mod_text: str) -> Any:
        # kipy 0.4 exposes Footprint.from_kicad_mod(text). Older builds may
        # require writing the text to a temp .kicad_mod file and calling
        # Board.add_footprint_from_file(). Try the in-memory path first.
        loader = getattr(_kipy_board_mod.Footprint, "from_kicad_mod", None)
        if callable(loader):
            return loader(kicad_mod_text)
        # Fallback: temp file.
        import os
        import tempfile

        tmpdir = tempfile.mkdtemp(prefix="eda-kicad-sync-")
        path = os.path.join(tmpdir, "tmp.kicad_mod")
        with open(path, "w", encoding="utf-8") as f:
            f.write(kicad_mod_text)
        loader_file = getattr(self._board, "load_footprint_from_file", None)
        if callable(loader_file):
            return loader_file(path)
        raise RuntimeError(
            "kipy build does not support loading a footprint from text or file; "
            "upgrade to kicad-python >= 0.4."
        )
