# IC package builder

Open **Library → New IC package** to generate an SMT footprint and a mechanical
STEP model from datasheet dimensions. Supported families are QFN, DFN, SOIC,
TSSOP and QFP. Existing generated cards expose **Edit package**.

Choose a family, enter the package dimensions, and enter the manufacturer's
recommended PCB land pattern. The templates contain illustrative dimensions:
review body, terminal, and land dimensions and mark them verified before saving.
The datasheet panel accepts a local PDF upload, a library PDF name, or an HTTP(S)
reference. Local PDFs open in the existing page-selectable PDF viewer; a remote
site may require opening its PDF separately if it disallows embedding.

All recipe dimensions are millimetres. The GUI can display and accept mils.
Body height is measured from the terminal seating plane, including standoff.
Terminal span is outside-to-outside; land span is **pad-center to pad-center**.
Contact length describes the flat terminal foot, not the complete gull-wing lead.
For packages without recommended lands, select explicit allowances and supply
toe, heel and side extensions. No IPC density/tolerance algorithm is implied.

Pin 1 starts at the upper end of the left row in the footprint top view. Select
clockwise numbering or rotate the package to match the drawing. Each side's pads
have stable side/ordinal identities. Rectangular packages may have different
counts on adjacent sides. Exposed pads have their own explicit number, physical
size, copper-land size, and stencil grid.

The model uses millimetres, X right, Y north, Z up, and seating plane Z=0. Its
body, individual terminals, exposed pad, and pin-1 mark are named analytic STEP
solids. Gull-wing leads use a dimensioned planar profile with straight bends.
They do not model manufacturing bend radii or body molding tolerances.

## CLI

```sh
netlisp package templates
netlisp package init --family qfn --name my-qfn --output my-qfn.json
# Edit the JSON dimensions; set dimensions_verified after reviewing them.
netlisp package check my-qfn.json
netlisp package preview my-qfn.json --output-dir preview
netlisp package save my-qfn.json --project-dir my-project
netlisp package show my-qfn --project-dir my-project --output editable.json
# Edit editable.json, preserving its revision, then save it to update the package.
netlisp package save editable.json --project-dir my-project
netlisp package export my-qfn --project-dir my-project --format step --output my-qfn.step
netlisp package export my-qfn --project-dir my-project --format kicad --output my-qfn.kicad_mod
```

`preview` writes `footprint.svg` and `model.step` without installing library
assets. `check` reports geometry diagnostics and the separate dimension-review
flag; valid example geometry can pass check while remaining unverified for save.
`save --component component-name` optionally assigns the package to an existing
local component. Its referenced pinout must match the package pad numbers exactly.

Structured twins are `package_templates`, `package_init`, `package_show`,
`package_preview`, `package_check`, `package_save`, and `package_export`:

```sh
netlisp tool package_init --args '{"family":"dfn","name":"my-dfn"}' --output my-dfn.json
netlisp tool package_show --project-dir my-project --args '{"name":"my-qfn"}'
# preview/check/save take {"recipe": <recipe object>}; save also accepts component.
netlisp tool package_save --project-dir my-project --args-file save-request.json
```

HTTP clients POST the same arguments to `/api/packages/<operation>` (use `export`
for export). Preview returns diagnostics, pad identities, the shared footprint
geometry description, SVG, STEP, and footprint source. Failures return a nonzero
CLI exit status or an HTTP error with actionable text. Revision and output-edit
conflicts return HTTP 409.

## Saved assets and precise editing

A save writes `lib/packages/<name>.json`, `lib/footprints/<name>.sexp`,
`lib/models/<name>.step`, and the explicit model association in
`lib/models/model-config.json`. Existing per-model placement settings are retained.
The package save uses the project mutation lock, stages all replacements, and
rolls back completed replacements if a later rename fails. This is not a
filesystem-wide atomic snapshot across a power loss.

Open the precise footprint editor to adjust pads, custom polygons, and artwork.
For generated footprints, its save records changed fields as recipe overrides.
Unchanged pad fields continue following the package dimensions. Additions and
removed pads are retained. Artwork changes override their corresponding layer.
The package page lists overrides with individual reset controls, a reset-all
button, and adjustment JSON for explicit remapping of a removed target.

Physical terminals always follow mechanical dimensions. Moving a copper land
never silently moves the 3D terminal. Inspect their alignment in the model view.
Topology changes with orphaned override targets fail validation. External edits
to generated footprint or STEP bytes block regeneration; duplicate the package
under a new name or restore the generated asset before proceeding.

The recipe loaded by `show` contains the revision needed for an update. Preserve
that revision while editing. Use the GUI Duplicate button, or change the name and
set `revision` to null, to create another package. Recipe/model hashes are managed
by the tool. Saving assets does not require rebuilding the Netlisp executable.

Stencil windows use `(paste (rect DX DY W H) ...)` inside the owning copper pad.
They are pad-relative rectangular openings, with no extra electrical pad IDs.
An absent form retains full-pad paste, `(paste)` suppresses paste, and `no-paste`
suppresses all openings. KiCad export uses unnumbered F.Paste-only pads; import
associates rectangular openings with a unique containing non-custom copper pad.
Unsupported or ambiguous stencil geometry is rejected on import. Generated QFN/DFN
windows round-trip without increasing electrical pad count.

BGA/LGA/DIP, automatic PDF extraction, IPC tolerance sizing, arbitrary solid
modeling, and schematic symbol generation are outside this version.
