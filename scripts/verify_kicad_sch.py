#!/usr/bin/env python3
"""Diff two KiCad s-expression netlists as net -> {(ref, pad)} sets.

Used by scripts/verify_kicad_sch.sh: side A is netlisp's own `export-kicad`
netlist (the flattener's truth), side B is the netlist KiCad produced by
reading back the `.kicad_sch` this project exported.

Normalisation applied to side B (all of it is KiCad behaviour, not ours):
  * `{slash}` and friends are KiCad's escape spelling; they are decoded back.
  * nets KiCad invents for open pads (`unconnected-(REF-PadN)`) are dropped,
    matching netlisp's code-0 "no net" bucket, which is dropped on side A.
Only ref/pad/net are compared — `pinfunction` is not (KiCad rewrites it as
"<pinname>_<pad>", for stock symbols too).

Normalisation applied to side A (this one is OURS, and deliberate):
  * a per-pin bypass-stub net `<base>.<REF>.<PAD>` is folded into `<base>`.
    netlisp's `(decouple … per-pin …)` shorthand carves one such micro-net off a
    rail per bypassed pad so the placer can measure each decoupling loop and the
    router can treat them as separate copper. KiCad has no notion of the
    convention, so the exported schematic labels every one of them with the rail
    name it belongs to — a user-requested display merge (see
    `src/kicad_sch/stub.zig`). The netlist and the file-based PCB sync keep the
    split and stay the board authority; the diff below is about the SCHEMATIC,
    so the netlisp side is folded the same way and every other net still has to
    match exactly. The rule is the exporter's, reproduced: the name must split
    into three non-empty parts on its last two dots, the net must carry `REF`'s
    own pad `PAD` (matched on the leaf of the flattened ref, and on a ref that
    is a real component), and a net named `<base>` must exist — so a design's
    genuinely dotted net name can never be folded.
"""

import re
import sys

TOKEN = re.compile(r'\(|\)|"(?:[^"\\]|\\.)*"|[^\s()]+')

ESCAPES = {
    "slash": "/",
    "brace": "{",
    "tab": "\t",
    "return": "\r",
    "newline": "\n",
    "dblquote": '"',
    "space": " ",
}


def parse(text):
    """Parse s-expression text into nested lists of strings."""
    stack = [[]]
    for tok in TOKEN.findall(text):
        if tok == "(":
            stack.append([])
        elif tok == ")":
            done = stack.pop()
            stack[-1].append(done)
        elif tok.startswith('"'):
            stack[-1].append(tok[1:-1].replace('\\"', '"').replace("\\\\", "\\"))
        else:
            stack[-1].append(tok)
    return stack[0]


def unescape(name):
    """Undo KiCad's `{token}` escapes in an exported net name."""
    return re.sub(r"\{(\w+)\}", lambda m: ESCAPES.get(m.group(1), m.group(0)), name)


def find(node, head):
    """Direct children of `node` whose first element is the atom `head`."""
    return [c for c in node if isinstance(c, list) and c and c[0] == head]


def value(node, head, default=""):
    hits = find(node, head)
    if hits and len(hits[0]) > 1 and isinstance(hits[0][1], str):
        return hits[0][1]
    return default


def load(path):
    """Return (components, nets) for one netlist file."""
    with open(path, encoding="utf-8") as fh:
        top = parse(fh.read())
    export = top[0]
    comps = set()
    for block in find(export, "components"):
        for comp in find(block, "comp"):
            comps.add(value(comp, "ref"))
    nets = {}
    for block in find(export, "nets"):
        for net in find(block, "net"):
            name = unescape(value(net, "name"))
            if not name or name.startswith("unconnected-"):
                continue
            members = set()
            for node in find(net, "node"):
                members.add((value(node, "ref"), value(node, "pin")))
            if members:
                nets.setdefault(name, set()).update(members)
    return comps, nets


def stub_base(name, members, comps, names):
    """The base rail `name` is a per-pin bypass stub of, or None.

    Mirrors `splitStubBase` in src/kicad_sch/stub.zig — keep the two in step.
    """
    dot = name.rfind(".")
    if dot < 0:
        return None
    prev = name.rfind(".", 0, dot)
    if prev < 0:
        return None
    base, ref, pad = name[:prev], name[prev + 1 : dot], name[dot + 1 :]
    if not base or not ref or not pad:
        return None
    if base not in names:
        return None
    for member_ref, member_pad in members:
        if member_pad == pad and member_ref.split("/")[-1] == ref and member_ref in comps:
            return base
    return None


def collapse_stubs(comps, nets):
    """Fold every per-pin bypass-stub net into its base rail, as the schematic
    labels them. Returns the folded net map plus how many nets were folded."""
    names = set(nets)
    folded = {}
    count = 0
    for name, members in nets.items():
        base = stub_base(name, members, comps, names)
        if base is None:
            folded.setdefault(name, set()).update(members)
        else:
            folded.setdefault(base, set()).update(members)
            count += 1
    return folded, count


def report(label, items, limit=12):
    items = sorted(items)
    for item in items[:limit]:
        print(f"    {label}: {item}")
    if len(items) > limit:
        print(f"    {label}: … and {len(items) - limit} more")


def main(argv):
    if len(argv) != 3:
        print("usage: verify_kicad_sch.py <netlisp.net> <kicad.net>", file=sys.stderr)
        return 2
    a_comps, a_nets = load(argv[1])
    b_comps, b_nets = load(argv[2])
    a_nets, folded = collapse_stubs(a_comps, a_nets)

    ok = True
    only_a = a_comps - b_comps
    only_b = b_comps - a_comps
    if only_a or only_b:
        ok = False
        print(f"  components differ: {len(a_comps)} netlisp vs {len(b_comps)} kicad")
        report("only in netlisp", only_a)
        report("only in kicad", only_b)

    # A net node naming a ref with no component is a netlisp-side artefact the
    # schematic cannot draw; it is reported by the exporter and ignored here.
    a_nets = {
        name: {m for m in members if m[0] in a_comps}
        for name, members in a_nets.items()
    }
    a_nets = {name: members for name, members in a_nets.items() if members}

    missing = set(a_nets) - set(b_nets)
    extra = set(b_nets) - set(a_nets)
    if missing or extra:
        ok = False
        print(f"  nets differ: {len(a_nets)} netlisp vs {len(b_nets)} kicad")
        report("missing in kicad", missing)
        report("extra in kicad", extra)

    for name in sorted(set(a_nets) & set(b_nets)):
        if a_nets[name] != b_nets[name]:
            ok = False
            print(f"  net '{name}' membership differs")
            report("missing", a_nets[name] - b_nets[name])
            report("extra", b_nets[name] - a_nets[name])

    if ok:
        note = f" ({folded} bypass stubs folded onto their rail)" if folded else ""
        print(f"  {len(a_comps)} components, {len(a_nets)} nets identical{note}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
