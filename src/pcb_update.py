#!/usr/bin/env python3
"""PCB updater for Canopy EDA.

Creates or updates a KiCad .kicad_pcb file from a Canopy netlist (.net),
matching components by stable UUID (stored as a hidden 'canopy_uuid' field
on each footprint) rather than by reference designator.

Usage:
    python3 pcb_update.py <netlist.net> <footprints.pretty> <output.kicad_pcb>

On first run, creates a new PCB with all footprints placed at the origin.
On subsequent runs, loads the existing PCB and:
  - Keeps placement/routing for components whose UUID still exists
  - Updates reference designators if they changed
  - Updates net assignments
  - Adds new components (placed at origin)
  - Removes components whose UUID is no longer in the netlist
"""

import sys
import os
import re
import json
import shutil
from datetime import datetime

sys.path.insert(0, "/usr/lib/python3/dist-packages")
import pcbnew


# ---------------------------------------------------------------------------
# Netlist parser (KiCad S-expression format, version "E")
# ---------------------------------------------------------------------------

def tokenize(text):
    """Tokenize an S-expression string into parens and atoms."""
    tokens = []
    i = 0
    while i < len(text):
        c = text[i]
        if c in "()":
            tokens.append(c)
            i += 1
        elif c == '"':
            j = i + 1
            while j < len(text) and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            tokens.append(text[i + 1 : j])
            i = j + 1
        elif c in " \t\n\r":
            i += 1
        else:
            j = i
            while j < len(text) and text[j] not in ' \t\n\r()"':
                j += 1
            tokens.append(text[i:j])
            i = j
    return tokens


def parse_sexp(tokens, pos=0):
    """Parse tokens into nested lists. Returns (node, next_pos)."""
    if tokens[pos] == "(":
        lst = []
        pos += 1
        while tokens[pos] != ")":
            node, pos = parse_sexp(tokens, pos)
            lst.append(node)
        return lst, pos + 1
    else:
        return tokens[pos], pos + 1


def parse_netlist(path):
    """Parse a .net file. Returns (components, nets).

    components: list of {ref, value, footprint, uuid, properties: {k: v}}
    nets: list of {code, name, nodes: [{ref, pin}]}
    """
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    return parse_netlist_text(text)


def parse_netlist_text(text):
    """Parse a netlist from a raw S-expression string. Same shape as
    `parse_netlist`. Used by the KiCad plugin path, which fetches netlists
    over HTTP (`GET /api/netlist/:name`) instead of reading a file."""
    tokens = tokenize(text)
    tree, _ = parse_sexp(tokens)

    components = []
    nets = []

    for item in tree[1:]:
        if not isinstance(item, list):
            continue

        if item[0] == "components":
            for comp in item[1:]:
                if not isinstance(comp, list) or comp[0] != "comp":
                    continue
                c = {"ref": "", "value": "", "footprint": "", "uuid": "", "properties": {}}
                for field in comp[1:]:
                    if not isinstance(field, list):
                        continue
                    tag = field[0]
                    if tag == "ref":
                        c["ref"] = field[1]
                    elif tag == "value":
                        c["value"] = field[1]
                    elif tag == "footprint":
                        c["footprint"] = field[1]
                    elif tag == "tstamp":
                        c["uuid"] = field[1]
                    elif tag == "property":
                        name = val = ""
                        for pf in field[1:]:
                            if isinstance(pf, list) and pf[0] == "name":
                                name = pf[1].strip()
                            elif isinstance(pf, list) and pf[0] == "value":
                                val = pf[1].strip()
                        # Skip corrupted properties
                        if name and name.isprintable() and not any(ord(ch) > 127 for ch in name):
                            c["properties"][name] = val
                components.append(c)

        elif item[0] == "nets":
            for net in item[1:]:
                if not isinstance(net, list) or net[0] != "net":
                    continue
                n = {"code": "", "name": "", "nodes": []}
                for field in net[1:]:
                    if not isinstance(field, list):
                        continue
                    tag = field[0]
                    if tag == "code":
                        n["code"] = field[1]
                    elif tag == "name":
                        n["name"] = field[1]
                    elif tag == "node":
                        node = {"ref": "", "pin": ""}
                        for nf in field[1:]:
                            if isinstance(nf, list):
                                if nf[0] == "ref":
                                    node["ref"] = nf[1]
                                elif nf[0] == "pin":
                                    node["pin"] = nf[1]
                        n["nodes"].append(node)
                nets.append(n)

    return components, nets


# ---------------------------------------------------------------------------
# PCB builder / updater
# ---------------------------------------------------------------------------

CANOPY_UUID_FIELD = "canopy_uuid"
CANOPY_NET_FIELD = "canopy_net"


def find_footprint_by_uuid(board, uuid):
    """Find a footprint in the board by its canopy_uuid field."""
    for fp in board.GetFootprints():
        if fp.HasFieldByName(CANOPY_UUID_FIELD):
            if fp.GetFieldText(CANOPY_UUID_FIELD) == uuid:
                return fp
    return None


def load_footprint(lib_path, footprint_spec):
    """Load a footprint from a .pretty library.

    footprint_spec is like 'footprints:R_0402_1005Metric'.
    Returns the footprint or None.
    """
    if ":" in footprint_spec:
        _, name = footprint_spec.split(":", 1)
    else:
        name = footprint_spec

    try:
        return pcbnew.FootprintLoad(lib_path, name)
    except Exception as e:
        print(f"  Warning: cannot load footprint '{name}' from {lib_path}: {e}")
        return None


def set_canopy_uuid(fp, uuid):
    """Set the canopy_uuid hidden field on a footprint."""
    if fp.HasFieldByName(CANOPY_UUID_FIELD):
        # Update existing
        field = fp.GetFieldByName(CANOPY_UUID_FIELD)
        field.SetText(uuid)
    else:
        field = pcbnew.PCB_FIELD(fp, fp.GetNextFieldId(), CANOPY_UUID_FIELD)
        field.SetText(uuid)
        field.SetVisible(False)
        fp.AddField(field)


def set_canopy_net(fp, net_str):
    """Set the canopy_net hidden field on a footprint."""
    if fp.HasFieldByName(CANOPY_NET_FIELD):
        field = fp.GetFieldByName(CANOPY_NET_FIELD)
        field.SetText(net_str)
    else:
        field = pcbnew.PCB_FIELD(fp, fp.GetNextFieldId(), CANOPY_NET_FIELD)
        field.SetText(net_str)
        field.SetVisible(False)
        fp.AddField(field)


def set_field(fp, name, value):
    """Set a visible field on a footprint, creating it if needed."""
    if fp.HasFieldByName(name):
        field = fp.GetFieldByName(name)
        field.SetText(value)
    else:
        field = pcbnew.PCB_FIELD(fp, fp.GetNextFieldId(), name)
        field.SetText(value)
        field.SetVisible(False)
        fp.AddField(field)


def sync_3d_models(board_fp, lib_fp):
    """Update 3D model on board footprint to match library footprint.

    Replaces all 3D model entries (filename, offset, rotation, scale)
    so the board stays in sync with model-config.json via the exported .kicad_mod.
    """
    lib_models = lib_fp.Models()
    board_models = board_fp.Models()

    # Compare: same count, same filenames, same transforms?
    if len(lib_models) == len(board_models):
        all_match = True
        for lm, bm in zip(lib_models, board_models):
            if (lm.m_Filename != bm.m_Filename or
                lm.m_Offset != bm.m_Offset or
                lm.m_Rotation != bm.m_Rotation or
                lm.m_Scale != bm.m_Scale):
                all_match = False
                break
        if all_match:
            return False  # no change needed

    # Clear existing models and copy from library
    board_fp.Models().clear()
    for lm in lib_models:
        board_fp.Models().append(lm)

    return True  # changed


def backup_pcb(pcb_path):
    """Create a timestamped backup of the PCB file."""
    if not os.path.exists(pcb_path):
        return None
    backup_dir = os.path.join(os.path.dirname(pcb_path), "canopy-backups")
    os.makedirs(backup_dir, exist_ok=True)
    base = os.path.basename(pcb_path)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_name = f"{os.path.splitext(base)[0]}_{ts}{os.path.splitext(base)[1]}"
    backup_path = os.path.join(backup_dir, backup_name)
    shutil.copy2(pcb_path, backup_path)
    print(f"Backup: {backup_path}")
    return backup_path


def snapshot_footprints(board):
    """Capture state of all canopy-tracked footprints for later comparison.

    Returns a dict keyed by canopy_uuid with position, orientation, layer,
    footprint name, and per-pad net/position.  Reference designator and value
    are intentionally excluded (they're expected to change).
    """
    snaps = {}
    for fp in board.GetFootprints():
        if not fp.HasFieldByName(CANOPY_UUID_FIELD):
            continue
        uuid = fp.GetFieldText(CANOPY_UUID_FIELD)
        if not uuid:
            continue
        pos = fp.GetPosition()
        snaps[uuid] = {
            "ref": fp.GetReference(),  # for error messages only
            "footprint_name": fp.GetFPID().GetUniStringLibItemName(),
            "pos_x": pos.x,
            "pos_y": pos.y,
            "orientation": fp.GetOrientation().AsDegrees(),
            "layer": fp.GetLayer(),
            "pads": {
                pad.GetNumber(): {
                    "net": pad.GetNetname(),
                    "pos_x": pad.GetPosition().x,
                    "pos_y": pad.GetPosition().y,
                }
                for pad in fp.Pads()
            },
        }
    return snaps


def verify_unchanged_footprints(before, after, changed_uuids):
    """Compare footprint state before/after update for components that should be unchanged.

    Returns a list of human-readable diff strings (empty = all good).
    Skips reference designator and value (expected to change).
    """
    diffs = []
    for uuid, old in before.items():
        if uuid in changed_uuids:
            continue
        if uuid not in after:
            continue  # removed component, not our concern
        new = after[uuid]
        ref_label = f"{new['ref']} (uuid={uuid[:8]})"

        if old["footprint_name"] != new["footprint_name"]:
            diffs.append(f"  {ref_label}: footprint changed: {old['footprint_name']} -> {new['footprint_name']}")
        if old["pos_x"] != new["pos_x"] or old["pos_y"] != new["pos_y"]:
            diffs.append(f"  {ref_label}: position changed: ({old['pos_x']},{old['pos_y']}) -> ({new['pos_x']},{new['pos_y']})")
        if abs(old["orientation"] - new["orientation"]) > 0.001:
            diffs.append(f"  {ref_label}: orientation changed: {old['orientation']} -> {new['orientation']}")
        if old["layer"] != new["layer"]:
            diffs.append(f"  {ref_label}: layer changed: {old['layer']} -> {new['layer']}")

        for pad_num, old_pad in old["pads"].items():
            new_pad = new["pads"].get(pad_num)
            if new_pad is None:
                diffs.append(f"  {ref_label}: pad {pad_num} disappeared")
                continue
            if old_pad["net"] != new_pad["net"]:
                diffs.append(f"  {ref_label}: pad {pad_num} net changed: '{old_pad['net']}' -> '{new_pad['net']}'")
            if old_pad["pos_x"] != new_pad["pos_x"] or old_pad["pos_y"] != new_pad["pos_y"]:
                diffs.append(f"  {ref_label}: pad {pad_num} position changed")
    return diffs


def load_sections(sections_path):
    """Load section layout JSON for grid-based placement."""
    if not sections_path or not os.path.exists(sections_path):
        return None
    try:
        with open(sections_path) as f:
            return json.load(f)
    except Exception:
        return None


def load_modules(modules_path):
    """Load modules.json sidecar.

    Returns a dict keyed by module name, with value = list of instance dicts
    {"path": "adc1", "refs": [...]}. Returns None if the sidecar is missing
    or unreadable — replication is then skipped.
    """
    if not modules_path or not os.path.exists(modules_path):
        return None
    try:
        with open(modules_path) as f:
            data = json.load(f)
    except Exception:
        return None
    grouped = {}
    for inst in data.get("instances", []):
        grouped.setdefault(inst["module"], []).append(inst)
    return grouped


def replicate_module_layouts(board, modules, existing_uuids, new_footprints,
                             comp_by_ref, stack_y_mm):
    """Seed new sub-block instances with a sibling's placement.

    For each module with ≥2 instances, if exactly one instance is already laid
    out (all UUIDs known to KiCad, non-default positions) and the others are
    all newly added, copy the master's per-component offset + orientation into
    each follower, shifted by `k * stack_y_mm` in Y.

    Mixed instances (partial placement) and multi-master cases (user has
    diverged) are skipped with a warning — one-shot semantics.

    Pre-seeded footprints are removed from `new_footprints` so Pass 2 grid
    placement leaves them alone. The caller is expected to filter
    section_fps / fallback_fps with the returned set.

    Returns the set of UUIDs that got seeded positions.
    """
    if not modules:
        return set()

    stack_y_nm = int(stack_y_mm * 1_000_000)
    seeded_uuids = set()

    for module_name, instances in modules.items():
        if len(instances) < 2:
            continue

        # Categorize each instance.
        masters = []
        followers = []
        mixed = False
        for inst in instances:
            refs = inst.get("refs", [])
            placed_fps = []
            new_fps = []
            for ref in refs:
                comp = comp_by_ref.get(ref)
                if not comp:
                    continue
                uuid = comp.get("uuid", "")
                if uuid in existing_uuids:
                    fp = existing_uuids[uuid]
                    pos = fp.GetPosition()
                    # Treat (0, 0) as "placeholder, not truly placed" — new
                    # footprints start there before grid layout runs.
                    if pos.x != 0 or pos.y != 0:
                        placed_fps.append((ref, fp, uuid))
                        continue
                if uuid in new_footprints:
                    new_fps.append((ref, new_footprints[uuid], uuid))

            if placed_fps and new_fps:
                mixed = True
                print(f"  Module '{module_name}' instance '{inst['path']}' "
                      f"has partial layout — skipping replication for this module.")
                break
            if placed_fps and not new_fps:
                masters.append((inst, placed_fps))
            elif new_fps and not placed_fps:
                followers.append((inst, new_fps))

        if mixed:
            continue
        if len(masters) == 0:
            continue  # nothing to copy from
        if len(masters) >= 2:
            # User has diverged layouts for this module — honor their choices.
            continue
        if len(followers) == 0:
            continue  # everything already placed

        master_inst, master_fps = masters[0]
        follower_list = sorted(followers, key=lambda f: f[0]["path"])

        # Build local_ref → master_fp map by stripping the master path prefix.
        master_prefix = master_inst["path"] + "/"
        master_local = {}
        for ref, fp, _uuid in master_fps:
            if ref.startswith(master_prefix):
                local = ref[len(master_prefix):]
                master_local[local] = fp

        for k, (f_inst, f_fps) in enumerate(follower_list, start=1):
            f_prefix = f_inst["path"] + "/"
            seeded_here = 0
            for ref, fp, uuid in f_fps:
                if not ref.startswith(f_prefix):
                    continue
                local = ref[len(f_prefix):]
                master_fp = master_local.get(local)
                if master_fp is None:
                    print(f"  Warning: follower '{ref}' has no matching "
                          f"master component '{master_prefix}{local}' — "
                          f"leaving at grid fallback.")
                    continue
                mpos = master_fp.GetPosition()
                fp.SetPosition(pcbnew.VECTOR2I(mpos.x, mpos.y + k * stack_y_nm))
                fp.SetOrientation(master_fp.GetOrientation())
                if master_fp.IsFlipped() and not fp.IsFlipped():
                    fp.Flip(fp.GetPosition(), pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
                seeded_uuids.add(uuid)
                seeded_here += 1
            if seeded_here:
                print(f"  Replicated '{master_inst['path']}' layout → "
                      f"'{f_inst['path']}' ({seeded_here} components, "
                      f"Y offset {k * stack_y_mm:.1f} mm).")

    return seeded_uuids


def shorten_net_name(name):
    """Collapse 'BASE.REF.PIN' to 'BASE' for power-pour-friendly net names.

    Heuristic: if the name contains a dot and the part after the first dot
    looks like a ref designator (letter(s) + digits), treat everything before
    the first dot as the base net name.
    """
    dot = name.find(".")
    if dot < 0:
        return name
    after = name[dot + 1:]
    # Check if next segment looks like a ref_des (e.g. U1, C36, R8)
    parts = after.split(".", 1)
    seg = parts[0]
    if seg and seg[0].isalpha() and any(c.isdigit() for c in seg):
        return name[:dot]
    return name


def merge_short_nets(nets):
    """Merge nets that share the same shortened name."""
    merged = {}  # short_name -> {nodes: [...], code: first_code}
    for net in nets:
        short = shorten_net_name(net["name"])
        if short not in merged:
            merged[short] = {"code": net["code"], "name": short, "nodes": []}
        # Deduplicate nodes (same ref+pin shouldn't appear twice)
        existing = {(n["ref"], n["pin"]) for n in merged[short]["nodes"]}
        for node in net["nodes"]:
            key = (node["ref"], node["pin"])
            if key not in existing:
                merged[short]["nodes"].append(node)
                existing.add(key)
    return list(merged.values())


def update_pcb(netlist_path, lib_path, pcb_path, sections_path=None, short_nets=False,
               modules_path=None, replicate_stack_y_mm=30.0):
    """Create or update a PCB from a netlist."""
    components, nets = parse_netlist(netlist_path)

    # Always build full (long) net lookup for canopy_net field tracking
    full_pin_to_net = {}
    for net in nets:
        for node in net["nodes"]:
            full_pin_to_net[(node["ref"], node["pin"])] = net["name"]
    ref_to_nets = {}
    for (ref, pin), net_name in full_pin_to_net.items():
        if net_name:
            ref_to_nets.setdefault(ref, set()).add(net_name)

    # Optionally shorten nets for pad assignments only
    if short_nets:
        nets = merge_short_nets(nets)
        print(f"  Short nets mode: merged to {len(nets)} nets")

    sections_data = load_sections(sections_path)

    # Build lookup for pad net assignments (may be shortened)
    pin_to_net = {}
    for net in nets:
        for node in net["nodes"]:
            pin_to_net[(node["ref"], node["pin"])] = net["name"]

    # Preflight: every component whose UUID isn't already on the board is about
    # to be added, and that requires its footprint to load. Fail fast (before
    # backup or any mutation) with the full list of missing footprints — we used
    # to skip silently and the user wouldn't notice a connector going missing.
    preflight_existing_uuids = set()
    if os.path.exists(pcb_path):
        preflight_board = pcbnew.LoadBoard(pcb_path)
        for fp in preflight_board.GetFootprints():
            if fp.HasFieldByName(CANOPY_UUID_FIELD):
                u = fp.GetFieldText(CANOPY_UUID_FIELD)
                if u:
                    preflight_existing_uuids.add(u)

    missing_fps = []
    for comp in components:
        if comp["uuid"] in preflight_existing_uuids:
            continue
        spec = comp.get("footprint", "")
        if not spec:
            missing_fps.append((comp["ref"], "(no footprint in netlist)"))
            continue
        if load_footprint(lib_path, spec) is None:
            missing_fps.append((comp["ref"], spec))

    if missing_fps:
        print("Preflight: missing footprints for new components:")
        for ref, spec in missing_fps:
            print(f"  {ref}: {spec}")
        raise RuntimeError(
            f"Cannot update PCB: {len(missing_fps)} footprint(s) not found in "
            f"library '{lib_path}'. PCB not modified, no backup written."
        )

    # Backup before modifying
    backup_path = backup_pcb(pcb_path)

    # Load or create board
    if os.path.exists(pcb_path):
        print(f"Loading existing PCB: {pcb_path}")
        board = pcbnew.LoadBoard(pcb_path)
    else:
        print(f"Creating new PCB: {pcb_path}")
        board = pcbnew.BOARD()

    comp_by_ref = {c["ref"]: c for c in components}

    netinfo = board.GetNetInfo()

    # Collect all net names we need
    net_names = set()
    for net in nets:
        if net["name"]:
            net_names.add(net["name"])

    # Add missing nets to board
    existing_nets = {str(name) for name, _ in netinfo.NetsByName().items()}
    for name in sorted(net_names):
        if name not in existing_nets:
            ni = pcbnew.NETINFO_ITEM(board, name)
            board.Add(ni)

    # Refresh netinfo after adding nets
    netinfo = board.GetNetInfo()
    nets_by_name = {str(name): ni for name, ni in netinfo.NetsByName().items()}

    # Track which UUIDs are in the netlist
    netlist_uuids = {c["uuid"] for c in components}

    # Signature-based remap: before we trust the canopy_uuid field, verify each
    # footprint's (value + canopy_net) signature against the current netlist.
    # If the signature uniquely identifies a netlist component, that's the
    # footprint's true logical identity — overwrite canopy_uuid (and Reference)
    # with the netlist's values. This corrects legacy misaligned UUIDs: e.g.,
    # when the BOM's ref_des-based Pass 1 preserved a UUID across a ref_des
    # shift, binding it to a different logical instance than the user placed.
    # Include the sub-block prefix ("adc1", "adc2", ...) as part of the
    # signature so that shared-rail caps (e.g. 1uF across V1P8 in three ADCs)
    # are still uniquely identifiable — same module, same sub-block, same
    # logical instance.
    def _sub_prefix(ref):
        return ref.split("/", 1)[0] if "/" in ref else ""

    netlist_sig_to_ref = {}
    for sig_ref, sig_nets in ref_to_nets.items():
        c = comp_by_ref.get(sig_ref)
        if c is None:
            continue
        sig = (c.get("value", "") or "") + "|" + ",".join(sorted(sig_nets)) + "|" + _sub_prefix(sig_ref)
        netlist_sig_to_ref.setdefault(sig, []).append(sig_ref)
    netlist_sig_unique = {sig: refs[0] for sig, refs in netlist_sig_to_ref.items() if len(refs) == 1}

    pcb_sig_to_fps = {}
    for fp in list(board.GetFootprints()):
        if not fp.HasFieldByName(CANOPY_UUID_FIELD) or not fp.HasFieldByName(CANOPY_NET_FIELD):
            continue
        fp_ref = fp.GetReference()
        sig = (fp.GetValue() or "") + "|" + fp.GetFieldText(CANOPY_NET_FIELD) + "|" + _sub_prefix(fp_ref)
        pcb_sig_to_fps.setdefault(sig, []).append(fp)

    # Step A: build full remap plan before applying anything, so we can detect
    # conflicts between a fp's stale uuid and another fp's intended new uuid.
    # (pcbnew.FOOTPRINT isn't hashable, so we key by id() and keep a list.)
    remap_plan = []  # (fp, new_uuid, netlist_ref, stored_uuid)
    for sig, pcb_fps in pcb_sig_to_fps.items():
        if len(pcb_fps) != 1:
            continue
        netlist_ref = netlist_sig_unique.get(sig)
        if netlist_ref is None:
            continue
        target = comp_by_ref.get(netlist_ref)
        if target is None:
            continue
        new_uuid = target["uuid"]
        if not new_uuid:
            continue
        fp = pcb_fps[0]
        stored_uuid = fp.GetFieldText(CANOPY_UUID_FIELD)
        if stored_uuid == new_uuid:
            continue
        remap_plan.append((fp, new_uuid, netlist_ref, stored_uuid))

    # Step B: find footprints that are NOT in the plan but currently hold a
    # UUID that the plan wants to assign elsewhere. Those are stale copies
    # whose identity drifted through BOM churn — the canonical owner of the
    # UUID is now somebody else, so these are orphans and must be removed.
    # (pcbnew returns fresh Python wrappers per GetFootprints() call, so we
    # key by the footprint's current canopy_uuid instead of id().)
    claimed_uuids = {nu for (_, nu, _, _) in remap_plan}
    planned_stored_uuids = {su for (_, _, _, su) in remap_plan}
    to_remove = []
    for fp in list(board.GetFootprints()):
        if not fp.HasFieldByName(CANOPY_UUID_FIELD):
            continue
        current_uuid = fp.GetFieldText(CANOPY_UUID_FIELD)
        if current_uuid in planned_stored_uuids:
            continue  # this fp is being remapped to a new uuid; don't remove
        if current_uuid in claimed_uuids:
            to_remove.append(fp)

    # Step C: apply — remove stale holders first, then commit remaps.
    for fp in to_remove:
        print(f"  Remove-dup: {fp.GetReference()} (stale uuid displaced by signature remap)")
        board.Remove(fp)

    sig_remap_count = 0
    for fp, new_uuid, netlist_ref, stored_uuid in remap_plan:
        old_ref = fp.GetReference()
        set_canopy_uuid(fp, new_uuid)
        if old_ref != netlist_ref:
            fp.SetReference(netlist_ref)
            print(f"  Sig-Remap: {old_ref} -> {netlist_ref} (uuid {stored_uuid[:8]}... -> {new_uuid[:8]}...)")
        else:
            print(f"  Sig-Remap: {netlist_ref} uuid {stored_uuid[:8]}... -> {new_uuid[:8]}...")
        sig_remap_count += 1
    if sig_remap_count:
        print(f"  Remapped {sig_remap_count} footprint(s) by signature")
    if to_remove:
        print(f"  Removed {len(to_remove)} stale footprint(s) displaced by signature remap")

    # Track which UUIDs already exist in the PCB (built AFTER sig-remap so the
    # remapped UUIDs are what the main loop sees).
    existing_uuids = {}
    for fp in board.GetFootprints():
        if fp.HasFieldByName(CANOPY_UUID_FIELD):
            existing_uuids[fp.GetFieldText(CANOPY_UUID_FIELD)] = fp

    # Snapshot existing footprint state for safety check
    before_snapshot = snapshot_footprints(board)
    changed_uuids = set()

    # Build net membership: net_name -> [(ref, pin), ...]
    net_members = {}
    for net in nets:
        net_members[net["name"]] = [(n["ref"], n["pin"]) for n in net["nodes"]]

    # Placement constants (nanometers)
    CELL_PAD = 3_000_000     # 3mm padding inside cell
    CELL_GAP = 5_000_000     # 5mm gap between cells
    GRID_ORIGIN_X = 20_000_000
    GRID_ORIGIN_Y = 30_000_000  # room for labels above
    COMP_GAP = 1_500_000     # 1.5mm gap between components
    MAX_ROW_WIDTH = 40_000_000  # 40mm max row width before wrapping

    # Build section lookup
    ref_section = {}
    section_list = []
    if sections_data:
        ref_section = sections_data.get("ref_section", {})
        section_list = sections_data.get("sections", [])

    def get_fp_size(fp):
        """Get footprint bounding box size in nm."""
        bb = fp.GetBoundingBox(False, False)
        return bb.GetWidth(), bb.GetHeight()

    # Collect new footprints per section for two-pass placement
    # Pass 1: add all footprints to the board, track per-section lists
    section_fps = {}  # section_idx -> [(fp, is_hub)]
    new_footprints = {}
    fallback_fps = []

    for comp in components:
        uuid = comp["uuid"]
        ref = comp["ref"]

        if uuid in existing_uuids:
            fp = existing_uuids[uuid]
            old_ref = fp.GetReference()
            if old_ref != ref:
                print(f"  Rename: {old_ref} -> {ref} (uuid={uuid[:8]}...)")
                fp.SetReference(ref)
            if fp.GetValue() != comp["value"]:
                changed_uuids.add(uuid)
            fp.SetValue(comp["value"])
            net_str = ",".join(sorted(ref_to_nets.get(ref, set())))
            if net_str:
                set_canopy_net(fp, net_str)
            if comp["properties"].get("mpn"):
                set_field(fp, "MPN", comp["properties"]["mpn"])

            # Check if footprint needs swapping
            nl_fp_spec = comp.get("footprint", "")
            nl_fp_name = nl_fp_spec.split(":")[-1] if ":" in nl_fp_spec else nl_fp_spec
            pcb_fp_name = fp.GetFPID().GetUniStringLibItemName()
            if nl_fp_name and pcb_fp_name != nl_fp_name:
                new_fp = load_footprint(lib_path, nl_fp_spec)
                if new_fp is not None:
                    # Preserve position, orientation, and board side
                    pos = fp.GetPosition()
                    orient = fp.GetOrientation()
                    was_back = fp.IsFlipped()
                    new_fp.SetReference(ref)
                    new_fp.SetValue(comp["value"])
                    set_canopy_uuid(new_fp, uuid)
                    swap_net_str = ",".join(sorted(ref_to_nets.get(ref, set())))
                    if swap_net_str:
                        set_canopy_net(new_fp, swap_net_str)
                    if comp["properties"].get("mpn"):
                        set_field(new_fp, "MPN", comp["properties"]["mpn"])
                    new_fp.Reference().SetVisible(False)
                    new_fp.Value().SetVisible(False)
                    board.Remove(fp)
                    board.Add(new_fp)
                    if was_back:
                        new_fp.Flip(pos, pcbnew.FLIP_DIRECTION_TOP_BOTTOM)
                    # Restore exact position/orientation — never move placed parts
                    new_fp.SetPosition(pos)
                    new_fp.SetOrientation(orient)
                    existing_uuids[uuid] = new_fp
                    changed_uuids.add(uuid)
                    print(f"  Swap footprint: {ref} {pcb_fp_name} -> {nl_fp_name}")
        else:
            fp = load_footprint(lib_path, comp["footprint"])
            if fp is None:
                # Preflight above should have caught this; if we land here, the
                # library changed mid-run or load_footprint is non-deterministic.
                raise RuntimeError(
                    f"Footprint load failed after preflight for {ref}: "
                    f"{comp['footprint']}"
                )

            fp.SetReference(ref)
            fp.SetValue(comp["value"])
            set_canopy_uuid(fp, uuid)
            new_net_str = ",".join(sorted(ref_to_nets.get(ref, set())))
            if new_net_str:
                set_canopy_net(fp, new_net_str)
            if comp["properties"].get("mpn"):
                set_field(fp, "MPN", comp["properties"]["mpn"])
            # Hide reference and value text on the board
            fp.Reference().SetVisible(False)
            fp.Value().SetVisible(False)
            fp.SetPosition(pcbnew.VECTOR2I(0, 0))  # temporary
            board.Add(fp)
            new_footprints[uuid] = fp
            print(f"  Add: {ref} ({comp['footprint']}) uuid={uuid[:8]}...")

            sec_idx = ref_section.get(ref)
            if sec_idx is not None:
                sec_idx = int(sec_idx)
                section_fps.setdefault(sec_idx, []).append((fp, fp.GetPadCount() >= 8))
            else:
                fallback_fps.append(fp)

    # Auto-layout replication (stacking adc2/adc3 under adc1) is disabled —
    # the user places repeated sub-block layouts manually in KiCad. Leave
    # `replicate_module_layouts` defined for a future re-enable.
    seeded_uuids = set()
    _ = replicate_stack_y_mm
    if seeded_uuids:
        # Remove seeded footprints from the grid-placement lists so Pass 2
        # doesn't overwrite their replicated positions.
        for sec_idx, fps_list in list(section_fps.items()):
            kept = [(fp, is_hub) for fp, is_hub in fps_list
                    if fp.GetFieldText(CANOPY_UUID_FIELD) not in seeded_uuids]
            if kept:
                section_fps[sec_idx] = kept
            else:
                del section_fps[sec_idx]
        fallback_fps = [fp for fp in fallback_fps
                        if fp.GetFieldText(CANOPY_UUID_FIELD) not in seeded_uuids]

    # Pass 2: lay out each section's components in a grid, measure cell size
    # Then position cells in a single row
    cell_extents = {}  # section_idx -> (width, height)

    for sec_idx, fps_list in section_fps.items():
        # Sort: hubs first, then passives
        hubs = [(fp, is_hub) for fp, is_hub in fps_list if is_hub]
        passives = [(fp, is_hub) for fp, is_hub in fps_list if not is_hub]
        ordered = hubs + passives

        # Place components in a grid at origin (0,0), we'll shift later
        cx, cy = CELL_PAD, CELL_PAD
        row_h = 0
        max_x = 0

        for fp, is_hub in ordered:
            w, h = get_fp_size(fp)

            # Wrap to next row if too wide
            if cx > CELL_PAD and cx + w > MAX_ROW_WIDTH:
                cy += row_h + COMP_GAP
                cx = CELL_PAD
                row_h = 0

            # Place component (center-based)
            fp.SetPosition(pcbnew.VECTOR2I(cx + w // 2, cy + h // 2))
            cx += w + COMP_GAP
            row_h = max(row_h, h)
            max_x = max(max_x, cx)

        cell_w = max_x + CELL_PAD
        cell_h = cy + row_h + CELL_PAD
        cell_extents[sec_idx] = (cell_w, cell_h)

    # Position cells in a grid layout
    # Collect cells in order, compute grid dimensions
    ordered_cells = [(si, cell_extents[si]) for si in range(len(section_list)) if si in cell_extents]
    n_cells = len(ordered_cells)

    if n_cells > 0:
        import math
        n_cols = math.ceil(math.sqrt(n_cells))
    else:
        n_cols = 1

    # Compute max width per column and max height per row
    col_widths = {}   # grid_col -> max width
    row_heights = {}  # grid_row -> max height
    for i, (si, (cw, ch)) in enumerate(ordered_cells):
        gc = i % n_cols
        gr = i // n_cols
        col_widths[gc] = max(col_widths.get(gc, 0), cw)
        row_heights[gr] = max(row_heights.get(gr, 0), ch)

    # Compute column X offsets and row Y offsets
    col_x = {}
    cx = GRID_ORIGIN_X
    for gc in range(max(col_widths.keys(), default=-1) + 1):
        col_x[gc] = cx
        cx += col_widths.get(gc, 0) + CELL_GAP

    row_y = {}
    ry = GRID_ORIGIN_Y
    for gr in range(max(row_heights.keys(), default=-1) + 1):
        row_y[gr] = ry
        ry += row_heights.get(gr, 0) + CELL_GAP

    # Place each cell at its grid position
    section_positions = {}  # section_idx -> (x, y, w, h)
    for i, (si, (cw, ch)) in enumerate(ordered_cells):
        gc = i % n_cols
        gr = i // n_cols
        fx = col_x[gc]
        fy = row_y[gr]
        section_positions[si] = (fx, fy, cw, ch)

        # Shift all footprints in this section from (0-based) to final position
        for fp, _ in section_fps.get(si, []):
            pos = fp.GetPosition()
            fp.SetPosition(pcbnew.VECTOR2I(pos.x + fx, pos.y + fy))

    # Place fallback components after the grid
    fallback_x = GRID_ORIGIN_X
    fallback_y = ry + CELL_GAP if row_heights else GRID_ORIGIN_Y
    for fp in fallback_fps:
        w, h = get_fp_size(fp)
        fp.SetPosition(pcbnew.VECTOR2I(fallback_x + w // 2, fallback_y + h // 2))
        fallback_x += w + COMP_GAP

    # Smart placement: place decoupling caps centered on the IC pad they decouple.
    # A decoupling cap is a 2-pad capacitor where one net is GND-like and the other
    # connects to a larger component (>= 8 pads). Only applies to newly-added caps.
    for comp in components:
        uuid = comp["uuid"]
        ref = comp["ref"]

        # Only process newly-added caps
        if uuid not in new_footprints:
            continue
        if not ref.rstrip("0123456789").endswith("C"):
            continue

        fp = new_footprints[uuid]
        if fp.GetPadCount() != 2:
            continue

        # Find the two nets this cap connects to
        cap_nets = []
        for pad in fp.Pads():
            net_name = pin_to_net.get((ref, pad.GetNumber()), "")
            cap_nets.append((pad.GetNumber(), net_name))

        if len(cap_nets) != 2:
            continue

        # Identify GND pin and signal pin
        gnd_pin = None
        sig_pin = None
        sig_net = None
        for pin_num, net_name in cap_nets:
            if not net_name:
                continue
            net_lower = net_name.lower()
            if "gnd" in net_lower or "vss" in net_lower:
                gnd_pin = pin_num
            else:
                sig_pin = pin_num
                sig_net = net_name

        if not sig_net:
            continue

        # Find an IC pad on the signal net to place this cap on
        members = net_members.get(sig_net, [])
        target_pad_pos = None
        for member_ref, member_pin in members:
            if member_ref == ref:
                continue
            # Find this component's footprint on the board
            target_fp = board.FindFootprintByReference(member_ref)
            if target_fp is None:
                continue
            # Only snap to "large" components (ICs, not other passives)
            if target_fp.GetPadCount() < 8:
                continue
            # Find the specific pad
            for tpad in target_fp.Pads():
                if tpad.GetNumber() == member_pin:
                    target_pad_pos = tpad.GetPosition()
                    break
            if target_pad_pos:
                break

        if target_pad_pos:
            fp.SetPosition(target_pad_pos)
            print(f"  Place: {ref} on {sig_net} pad")

    # Remove footprints whose UUID is gone from the netlist
    to_remove = []
    for fp in board.GetFootprints():
        if fp.HasFieldByName(CANOPY_UUID_FIELD):
            fuuid = fp.GetFieldText(CANOPY_UUID_FIELD)
            if fuuid and fuuid not in netlist_uuids:
                to_remove.append(fp)

    # Also remove duplicate ref_des: if a ref has both a canopy-tracked and
    # untracked footprint, remove the untracked one (stale from KiCad)
    ref_to_canopy = {}
    for fp in board.GetFootprints():
        if fp.HasFieldByName(CANOPY_UUID_FIELD) and fp.GetFieldText(CANOPY_UUID_FIELD):
            ref_to_canopy[fp.GetReference()] = fp
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        if ref in ref_to_canopy and fp != ref_to_canopy[ref]:
            if not fp.HasFieldByName(CANOPY_UUID_FIELD) or not fp.GetFieldText(CANOPY_UUID_FIELD):
                to_remove.append(fp)

    for fp in to_remove:
        print(f"  Remove: {fp.GetReference()} (uuid={fp.GetFieldText(CANOPY_UUID_FIELD)[:8]}...)")
        board.Remove(fp)

    # Update net assignments on all pads
    for fp in board.GetFootprints():
        ref = fp.GetReference()
        for pad in fp.Pads():
            pin = pad.GetNumber()
            net_name = pin_to_net.get((ref, pin), "")
            if net_name and net_name in nets_by_name:
                pad.SetNet(nets_by_name[net_name])
            else:
                # Unconnected
                pad.SetNet(nets_by_name.get("", netinfo.GetNetItem(0)))

    # Sync 3D models: ensure every footprint has the correct model from the library
    for comp in components:
        ref = comp["ref"]
        fp_spec = comp.get("footprint", "")
        if not fp_spec:
            continue
        board_fp = board.FindFootprintByReference(ref)
        if board_fp is None:
            continue
        lib_fp = load_footprint(lib_path, fp_spec)
        if lib_fp is None:
            continue
        lib_models = lib_fp.Models()
        if len(lib_models) == 0:
            continue
        board_models = board_fp.Models()
        # Check if models already match
        needs_update = len(lib_models) != len(board_models)
        if not needs_update:
            for lm, bm in zip(lib_models, board_models):
                if lm.m_Filename != bm.m_Filename:
                    needs_update = True
                    break
        if needs_update:
            board_fp.Models().clear()
            for lm in lib_models:
                board_fp.Models().append(lm)
            print(f"  Sync 3D model: {ref} -> {lib_models[0].m_Filename}")

    # Check which section cells still have footprints inside them (after cap snap)
    occupied_sections = set()
    for si, (sx, sy, sw, sh) in section_positions.items():
        for fp, _ in section_fps.get(si, []):
            pos = fp.GetPosition()
            if sx <= pos.x <= sx + sw and sy <= pos.y <= sy + sh:
                occupied_sections.add(si)
                break

    # Draw section cell borders and labels on User.9 layer
    # (User.1 is reserved for user drawings — never modify it)
    SECTION_LAYER = pcbnew.User_9
    if section_positions:
        # Remove old auto-generated section drawings on our layer
        to_del = []
        for drawing in board.GetDrawings():
            if hasattr(drawing, 'GetLayer') and drawing.GetLayer() == SECTION_LAYER:
                to_del.append(drawing)
        for d in to_del:
            board.Remove(d)

        LABEL_OFFSET = 3_000_000  # 3mm above cell for label
        LINE_WIDTH = int(0.15 * 1_000_000)  # 0.15mm
        TEXT_SIZE = pcbnew.VECTOR2I(2_000_000, 2_000_000)  # 2mm text

        for si, (x1, y1, cw, ch) in section_positions.items():
            if si not in occupied_sections:
                continue
            sec = section_list[si]
            x2 = x1 + cw
            y2 = y1 + ch

            # Rectangle border
            rect = pcbnew.PCB_SHAPE(board)
            rect.SetShape(pcbnew.SHAPE_T_RECT)
            rect.SetStart(pcbnew.VECTOR2I(x1, y1))
            rect.SetEnd(pcbnew.VECTOR2I(x2, y2))
            rect.SetLayer(SECTION_LAYER)
            rect.SetWidth(LINE_WIDTH)
            board.Add(rect)

            # Section label above the cell
            text = pcbnew.PCB_TEXT(board)
            text.SetText(sec["name"])
            text.SetPosition(pcbnew.VECTOR2I(x1 + cw // 2, y1 - LABEL_OFFSET))
            text.SetTextSize(TEXT_SIZE)
            text.SetLayer(SECTION_LAYER)
            board.Add(text)

    # Safety check: verify unchanged components weren't corrupted
    after_snapshot = snapshot_footprints(board)
    diffs = verify_unchanged_footprints(before_snapshot, after_snapshot, changed_uuids)
    if diffs:
        # Check if all diffs are net-only changes (safe for migration)
        net_only = all("net changed" in d for d in diffs)
        print(f"\n  Safety check: {len(diffs)} change(s) detected" + (" (net names only — allowing)" if net_only else ""))
        for d in diffs:
            print(d)
        if not net_only:
            raise RuntimeError(
                f"PCB update safety check failed: {len(diffs)} unexpected change(s). "
                f"Board NOT saved. Backup at: {backup_path}"
            )

    board.Save(pcb_path)
    print(f"Saved: {pcb_path}")
    print(f"  {len(components)} components, {len(nets)} nets")

    # ── Validation: compare netlist vs PCB ─────────────────────────────────
    print("\n  Validation:")
    mismatches = []  # list of {ref, kind, pcb, netlist, pin?}
    missing = []     # list of refs on netlist but not on PCB

    netlist_by_ref = {c["ref"]: c for c in components}
    netlist_pin_nets = {}
    for net in nets:
        for node in net["nodes"]:
            netlist_pin_nets.setdefault(node["ref"], {})[node["pin"]] = net["name"]

    for fp in board.GetFootprints():
        ref = fp.GetReference()
        if ref not in netlist_by_ref:
            continue
        nl = netlist_by_ref[ref]

        pcb_value = fp.GetValue()
        nl_value = nl.get("value", "")
        if nl_value and pcb_value != nl_value:
            mismatches.append({"ref": ref, "kind": "value", "pcb": pcb_value, "netlist": nl_value})

        pcb_fp = fp.GetFPID().GetUniStringLibItemName()
        nl_fp = nl.get("footprint", "")
        if nl_fp:
            nl_fp_name = nl_fp.split(":")[-1] if ":" in nl_fp else nl_fp
            if pcb_fp != nl_fp_name:
                mismatches.append({"ref": ref, "kind": "footprint", "pcb": pcb_fp, "netlist": nl_fp_name})

        ref_pin_nets = netlist_pin_nets.get(ref, {})
        for pad in fp.Pads():
            pin = pad.GetNumber()
            pcb_net = pad.GetNetname()
            nl_net = ref_pin_nets.get(pin, "")
            if nl_net and pcb_net and pcb_net != nl_net:
                mismatches.append({"ref": ref, "pin": pin, "kind": "net", "pcb": pcb_net, "netlist": nl_net})

    pcb_refs = {fp.GetReference() for fp in board.GetFootprints()}
    for comp in components:
        if comp["ref"] not in pcb_refs:
            missing.append(comp["ref"])

    for m in mismatches:
        if "pin" in m:
            print(f"    MISMATCH {m['ref']}.{m['pin']} {m['kind']}: PCB='{m['pcb']}' netlist='{m['netlist']}'")
        else:
            print(f"    MISMATCH {m['ref']} {m['kind']}: PCB='{m['pcb']}' netlist='{m['netlist']}'")
    for r in missing:
        print(f"    MISSING {r} not on PCB")

    errors = len(mismatches) + len(missing)
    if errors == 0:
        print("    All checks passed")
    else:
        print(f"    {errors} issue(s) found")

    # Machine-parseable summary, consumed by the server + UI.
    diff_path = os.path.splitext(pcb_path)[0] + ".pcb_diff.json"
    summary = {
        "pcb": pcb_path,
        "backup": backup_path,
        "components": len(components),
        "nets": len(nets),
        "mismatches": mismatches,
        "missing": missing,
    }
    try:
        with open(diff_path, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"  Diff report: {diff_path}")
    except Exception as e:
        print(f"  Warning: could not write {diff_path}: {e}")

    # Single-line summary the server can grep out of stdout without parsing JSON.
    print(f"SUMMARY mismatches={len(mismatches)} missing={len(missing)} "
          f"seeded={len(seeded_uuids)} backup={backup_path or '-'}")

    return 0 if errors == 0 else 2


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    # Strip flags, keep positional args.
    args = []
    short_nets = False
    modules_path = None
    replicate_stack_y_mm = 30.0
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--short-nets":
            short_nets = True
        elif a == "--modules":
            modules_path = next(it, None)
        elif a == "--replicate-stack-y":
            try:
                replicate_stack_y_mm = float(next(it, "30"))
            except ValueError:
                replicate_stack_y_mm = 30.0
        else:
            args.append(a)

    if len(args) < 3 or len(args) > 4:
        print(f"Usage: {sys.argv[0]} [--short-nets] [--modules <modules.json>] [--replicate-stack-y <mm>] <netlist.net> <footprints.pretty> <output.kicad_pcb> [sections.json]")
        print()
        print("Creates or updates a KiCad PCB from a Canopy EDA netlist.")
        print("Components are tracked by stable UUID, not reference designator.")
        print("Optional sections.json enables section-based grid placement.")
        print()
        print("  --short-nets            Collapse per-pin nets (VDD.U1.F7) to base name (VDD)")
        print("  --modules <path>        Modules JSON sidecar; enables one-shot layout replication")
        print("                          for identical sub-block instances (e.g. 3x ADC channel).")
        print("  --replicate-stack-y N   Y offset between stacked follower instances (mm, default 30).")
        sys.exit(1)

    netlist_path = args[0]
    lib_path = args[1]
    pcb_path = args[2]
    sections_path = args[3] if len(args) > 3 else None

    if not os.path.exists(netlist_path):
        print(f"Error: netlist not found: {netlist_path}")
        sys.exit(1)

    if not os.path.isdir(lib_path):
        print(f"Error: footprint library not found: {lib_path}")
        sys.exit(1)

    sys.exit(update_pcb(
        netlist_path, lib_path, pcb_path, sections_path,
        short_nets=short_nets,
        modules_path=modules_path,
        replicate_stack_y_mm=replicate_stack_y_mm,
    ))


if __name__ == "__main__":
    main()
