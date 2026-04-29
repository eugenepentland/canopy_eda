"""KiCad netlist parser (S-expression format, version "E").

Ported from src/pcb_update.py — the source of truth for how Canopy emits
netlists. Standalone (no KiCad dependency) so it can be unit-tested.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List


@dataclass
class Component:
    ref: str
    value: str
    footprint: str
    uuid: str
    properties: dict[str, str] = field(default_factory=dict)


@dataclass
class Node:
    ref: str
    pin: str


@dataclass
class Net:
    code: str
    name: str
    nodes: List[Node] = field(default_factory=list)


@dataclass
class Netlist:
    components: List[Component]
    nets: List[Net]


def _tokenize(text: str) -> list[str]:
    tokens: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in "()":
            tokens.append(c)
            i += 1
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            tokens.append(text[i + 1 : j])
            i = j + 1
        elif c in " \t\n\r":
            i += 1
        else:
            j = i
            while j < n and text[j] not in ' \t\n\r()"':
                j += 1
            tokens.append(text[i:j])
            i = j
    return tokens


def _parse(tokens: list[str], pos: int = 0):
    if tokens[pos] == "(":
        out: list = []
        pos += 1
        while tokens[pos] != ")":
            node, pos = _parse(tokens, pos)
            out.append(node)
        return out, pos + 1
    return tokens[pos], pos + 1


def parse(text: str) -> Netlist:
    """Parse a netlist string (as returned by GET /api/netlist/:name)."""
    tree, _ = _parse(_tokenize(text))

    components: list[Component] = []
    nets: list[Net] = []

    for item in tree[1:]:
        if not isinstance(item, list):
            continue
        head = item[0]

        if head == "components":
            for comp in item[1:]:
                if not isinstance(comp, list) or comp[0] != "comp":
                    continue
                c = Component(ref="", value="", footprint="", uuid="")
                for fld in comp[1:]:
                    if not isinstance(fld, list):
                        continue
                    tag = fld[0]
                    if tag == "ref":
                        c.ref = fld[1]
                    elif tag == "value":
                        c.value = fld[1]
                    elif tag == "footprint":
                        c.footprint = fld[1]
                    elif tag == "tstamp":
                        c.uuid = fld[1]
                    elif tag == "property":
                        name = val = ""
                        for pf in fld[1:]:
                            if isinstance(pf, list) and pf[0] == "name":
                                name = pf[1].strip()
                            elif isinstance(pf, list) and pf[0] == "value":
                                val = pf[1].strip()
                        if name and name.isprintable() and not any(ord(ch) > 127 for ch in name):
                            c.properties[name] = val
                components.append(c)

        elif head == "nets":
            for net in item[1:]:
                if not isinstance(net, list) or net[0] != "net":
                    continue
                n = Net(code="", name="")
                for fld in net[1:]:
                    if not isinstance(fld, list):
                        continue
                    tag = fld[0]
                    if tag == "code":
                        n.code = fld[1]
                    elif tag == "name":
                        n.name = fld[1]
                    elif tag == "node":
                        nd = Node(ref="", pin="")
                        for nf in fld[1:]:
                            if isinstance(nf, list):
                                if nf[0] == "ref":
                                    nd.ref = nf[1]
                                elif nf[0] == "pin":
                                    nd.pin = nf[1]
                        n.nodes.append(nd)
                nets.append(n)

    return Netlist(components=components, nets=nets)


def pad_net_map(nl: Netlist) -> dict[tuple[str, str], str]:
    """Build {(ref, pin) -> net_name} from a parsed netlist."""
    out: dict[tuple[str, str], str] = {}
    for n in nl.nets:
        if not n.name:
            continue
        for nd in n.nodes:
            out[(nd.ref, nd.pin)] = n.name
    return out
