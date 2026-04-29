"""Sync engine tests using a fake BoardAdapter — no kipy / KiCad needed."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from plugins import netlist_parser, sync_core


# ── Fake adapter ─────────────────────────────────────────────────────────


@dataclass
class FakeFp:
    ref: str = ""
    value: str = ""
    footprint_name: str = ""
    fields: dict[str, str] = field(default_factory=dict)
    pad_nets: dict[str, str] = field(default_factory=dict)
    pad_numbers: list[str] = field(default_factory=list)


class FakeBoard:
    def __init__(self, footprints: list[FakeFp]):
        self._fps = list(footprints)
        self.commit_messages: list[str] = []
        self.added: list[FakeFp] = []
        self.removed: list[FakeFp] = []

    def list_footprints(self):
        return list(self._fps)

    def get_field(self, fp, name):
        return fp.fields.get(name, "")

    def get_reference(self, fp):
        return fp.ref

    def get_footprint_name(self, fp):
        return fp.footprint_name

    def set_field(self, fp, name, value):
        fp.fields[name] = value

    def set_reference(self, fp, ref):
        fp.ref = ref

    def set_value(self, fp, value):
        fp.value = value

    def set_pad_net(self, fp, pad_number, net_name):
        if pad_number not in fp.pad_numbers:
            raise KeyError(pad_number)
        fp.pad_nets[pad_number] = net_name

    def add_footprint(self, kicad_mod_text, ref, value, uuid):
        # Use the first line of kicad_mod_text after `(footprint "..."` as fp name.
        new = FakeFp(
            ref=ref,
            value=value,
            footprint_name=_extract_fp_name(kicad_mod_text),
            fields={"canopy_uuid": uuid},
            pad_numbers=["1", "2"],
        )
        self._fps.append(new)
        self.added.append(new)
        return new

    def swap_footprint(self, fp, kicad_mod_text, new_footprint_name):
        new = FakeFp(
            ref=fp.ref,
            value=fp.value,
            footprint_name=new_footprint_name,
            fields=dict(fp.fields),
            pad_numbers=list(fp.pad_numbers),
            pad_nets=dict(fp.pad_nets),
        )
        self._fps = [f if f is not fp else new for f in self._fps]
        self.added.append(new)
        self.removed.append(fp)
        return new

    def remove_footprint(self, fp):
        if fp in self._fps:
            self._fps.remove(fp)
        self.removed.append(fp)

    def begin_commit(self):
        return object()

    def push_commit(self, commit, message):
        self.commit_messages.append(message)


class FakeFpSource:
    def __init__(self, mods: dict[str, str]):
        self._mods = mods

    def get_kicad_mod(self, name):
        return self._mods.get(name)


def _extract_fp_name(text: str) -> str:
    # Tiny extractor: grabs the first quoted name after `(footprint`.
    after = text.split("(footprint", 1)[-1]
    quoted = after.split('"', 2)
    return quoted[1] if len(quoted) > 1 else ""


# ── Fixtures ─────────────────────────────────────────────────────────────


NETLIST_BASE = """
(export (version "E")
  (components
    (comp (ref "R1") (value "10k") (footprint "lib:R_0402") (tstamp "uuid-r1"))
    (comp (ref "C1") (value "100nF") (footprint "lib:C_0402") (tstamp "uuid-c1")))
  (nets
    (net (code "1") (name "VDD")
      (node (ref "R1") (pin "1"))
      (node (ref "C1") (pin "1")))
    (net (code "2") (name "GND")
      (node (ref "R1") (pin "2"))
      (node (ref "C1") (pin "2")))))
"""


def _r0402_mod():
    return '(footprint "R_0402")'


def _c0402_mod():
    return '(footprint "C_0402")'


def _r0805_mod():
    return '(footprint "R_0805")'


def _fp_source():
    return FakeFpSource({"R_0402": _r0402_mod(), "C_0402": _c0402_mod(), "R_0805": _r0805_mod()})


# ── Tests ────────────────────────────────────────────────────────────────


def test_pure_update_changes_value_and_nets():
    existing_r1 = FakeFp(
        ref="R1", value="1k", footprint_name="R_0402",
        fields={"canopy_uuid": "uuid-r1"}, pad_numbers=["1", "2"],
    )
    existing_c1 = FakeFp(
        ref="C1", value="100nF", footprint_name="C_0402",
        fields={"canopy_uuid": "uuid-c1"}, pad_numbers=["1", "2"],
    )
    board = FakeBoard([existing_r1, existing_c1])
    nl = netlist_parser.parse(NETLIST_BASE)

    summary = sync_core.sync(board, nl, _fp_source())

    assert set(summary.updated) == {"R1", "C1"}
    assert summary.added == [] and summary.removed == [] and summary.swapped == []
    assert existing_r1.value == "10k"
    assert existing_r1.pad_nets == {"1": "VDD", "2": "GND"}
    assert board.commit_messages, "commit was not pushed"


def test_add_new_component_at_origin():
    existing_r1 = FakeFp(
        ref="R1", value="10k", footprint_name="R_0402",
        fields={"canopy_uuid": "uuid-r1"}, pad_numbers=["1", "2"],
    )
    board = FakeBoard([existing_r1])
    nl = netlist_parser.parse(NETLIST_BASE)

    summary = sync_core.sync(board, nl, _fp_source())

    assert summary.added == ["C1"]
    new_c1 = next(f for f in board.added if f.ref == "C1")
    assert new_c1.fields["canopy_uuid"] == "uuid-c1"
    assert new_c1.pad_nets == {"1": "VDD", "2": "GND"}


def test_uuid_match_handles_renamed_refdes():
    # On board: R7 with the same uuid the netlist now calls R1.
    fp = FakeFp(
        ref="R7", value="1k", footprint_name="R_0402",
        fields={"canopy_uuid": "uuid-r1"}, pad_numbers=["1", "2"],
    )
    c1 = FakeFp(
        ref="C1", value="100nF", footprint_name="C_0402",
        fields={"canopy_uuid": "uuid-c1"}, pad_numbers=["1", "2"],
    )
    board = FakeBoard([fp, c1])
    nl = netlist_parser.parse(NETLIST_BASE)

    sync_core.sync(board, nl, _fp_source())

    assert fp.ref == "R1", "ref-des should be rewritten to match the netlist"
    assert board.added == [], "should not have added a duplicate footprint"


def test_footprint_swap_when_name_changes():
    fp = FakeFp(
        ref="R1", value="10k", footprint_name="R_0402",
        fields={"canopy_uuid": "uuid-r1"}, pad_numbers=["1", "2"],
    )
    c1 = FakeFp(
        ref="C1", value="100nF", footprint_name="C_0402",
        fields={"canopy_uuid": "uuid-c1"}, pad_numbers=["1", "2"],
    )
    board = FakeBoard([fp, c1])
    netlist_text = NETLIST_BASE.replace("lib:R_0402", "lib:R_0805")
    nl = netlist_parser.parse(netlist_text)

    summary = sync_core.sync(board, nl, _fp_source())

    assert summary.swapped == ["R1"]
    assert any(a.footprint_name == "R_0805" for a in board.added)
    assert fp in board.removed


def test_stale_flagged_by_default_and_pruned_when_requested():
    extra = FakeFp(
        ref="X9", value="x", footprint_name="X_x",
        fields={"canopy_uuid": "uuid-stale"}, pad_numbers=["1"],
    )
    fp_r1 = FakeFp(
        ref="R1", value="10k", footprint_name="R_0402",
        fields={"canopy_uuid": "uuid-r1"}, pad_numbers=["1", "2"],
    )
    fp_c1 = FakeFp(
        ref="C1", value="100nF", footprint_name="C_0402",
        fields={"canopy_uuid": "uuid-c1"}, pad_numbers=["1", "2"],
    )

    board = FakeBoard([fp_r1, fp_c1, extra])
    nl = netlist_parser.parse(NETLIST_BASE)
    summary = sync_core.sync(board, nl, _fp_source())
    assert summary.flagged_stale == ["X9"]
    assert summary.removed == []

    board2 = FakeBoard([
        FakeFp(ref="R1", value="10k", footprint_name="R_0402",
               fields={"canopy_uuid": "uuid-r1"}, pad_numbers=["1", "2"]),
        FakeFp(ref="C1", value="100nF", footprint_name="C_0402",
               fields={"canopy_uuid": "uuid-c1"}, pad_numbers=["1", "2"]),
        FakeFp(ref="X9", value="x", footprint_name="X_x",
               fields={"canopy_uuid": "uuid-stale"}, pad_numbers=["1"]),
    ])
    summary2 = sync_core.sync(board2, nl, _fp_source(), prune_stale=True)
    assert summary2.removed == ["X9"]


def test_unmanaged_footprints_left_alone_when_pruning():
    # A footprint without a canopy_uuid should never be touched, even with --prune.
    user_fp = FakeFp(
        ref="MOUNT1", value="", footprint_name="hole",
        fields={}, pad_numbers=["1"],
    )
    fp_r1 = FakeFp(
        ref="R1", value="10k", footprint_name="R_0402",
        fields={"canopy_uuid": "uuid-r1"}, pad_numbers=["1", "2"],
    )
    fp_c1 = FakeFp(
        ref="C1", value="100nF", footprint_name="C_0402",
        fields={"canopy_uuid": "uuid-c1"}, pad_numbers=["1", "2"],
    )
    board = FakeBoard([fp_r1, fp_c1, user_fp])
    nl = netlist_parser.parse(NETLIST_BASE)
    summary = sync_core.sync(board, nl, _fp_source(), prune_stale=True)
    assert "MOUNT1" not in summary.removed
    assert "MOUNT1" not in summary.flagged_stale
