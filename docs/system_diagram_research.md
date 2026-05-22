# Designing Auto-Generated Block Diagrams for an S-Expression EDA Tool

This report is the working brief for evolving co-circuit's diagram generator from a fixed compass layout into a domain-aware, multi-page block-diagram pipeline that can serve MCU boards, analog/RF daughterboards, RF frontends, and RF basebands. It is structured in two halves: **Part A — visual / diagrammatic conventions** (what diagrams should *look* like) and **Part B — algorithmic / layout** (how to *compute* them), followed by an opinionated **DSL extension proposal**.

---

## Part A — Visual & Diagrammatic Conventions

### A1. What silicon-vendor datasheet block diagrams actually do

Survey the front-page block diagrams of TI (TPS6594, TPS628x family), ADI (AD7380, ADF4368, ADAR1000), ST (STM32N6, STM32H7), NXP (PF5020, i.MX RT), Microchip (SAM/PIC32 series), and Bosch (BNO086). Across all of them, a consistent vocabulary emerges:

**Block shapes and what they signify**
- **Plain rectangles with name + role** — generic functional blocks (cores, peripherals, memory). Most datasheet diagrams use a 1–2px black border, white or pale-tinted fill, with a small bold label and one or two lines of role text underneath ("ADC 12-bit / 2 MSPS").
- **Rounded rectangles** — often used by ST/NXP to indicate "soft" or programmable subsystems (DMA, NVIC, peripheral fabrics).
- **Stacked rectangles with internal tick marks** — memory arrays (Flash, SRAM, OTP).
- **Triangles pointing in the signal direction** — amplifiers, drivers, buffers. The tip is always the output.
- **Trapezoids** — multiplexers (long edge = inputs, short edge = output); also used for level shifters and PGAs in ADI parts.
- **Circles** — summers/junctions (with `Σ` glyph), comparators, mixers (with `×` glyph), oscillators (with `~` glyph), PLLs (often labelled `÷N`/`÷R` around a phase detector).
- **Bevelled/parallelogram or shield outlines** — security, crypto, tamper blocks (common in ST/NXP).
- **Heavy outline / drop shadow** — emphasises the device under discussion. The chip die itself is typically drawn as one large outer rectangle, with everything inside it being on-die.
- **Dashed/dotted outlines** — power domains, "optional" or "external" blocks, voltage islands.
- **Diagonally hatched fill** — analog (vs. digital) domain.

**Pins, ports, and edges**
- Pins/balls of the package appear at the diagram boundary as labeled stubs, typically with a 5–8 character mnemonic (`VDDIO`, `SCL1`, `BOOT0`).
- Buses are drawn as a single thicker line, optionally with a diagonal slash + integer for width (e.g., a slash with `/32` for a 32-bit bus). The internal bus matrix is itself a rectangle that contains tagged stubs.
- **Arrows convey direction**: solid arrowhead for unidirectional, open or "double-ended" arrowhead for bidirectional. Many ST diagrams omit arrows on AHB/APB buses and use only diamond-tipped connections where bus-masters tap.
- **Power and ground are deliberately stylised differently from signals**: typically thicker lines, often shown only as short stubs leaving the die boundary (e.g., the AD7380 datasheet uses dedicated `AVDD/AVSS/REFIN` stubs on the top edge). Ground is sometimes drawn as a downward triangle within the block rather than routed.

**What separates a good block diagram from a bad one (synthesised from the survey)**
- Good: ≤ ~20 top-level blocks per page; consistent left-to-right or top-to-bottom signal flow; one clear "subject" block (e.g. the core matrix); ports labelled at the edge; buses collapsed; one decoration meaning per visual property (don't reuse colour for both rail and domain).
- Bad: > 30 blocks; mixed flow directions; passives (R/C) drawn at this level; inconsistent shapes; long unbroken edges crossing many blocks; pin numbers shown at this level.

**Power vs. signal in vendor diagrams.** Vendors that ship a PMIC (TI TPS6594, NXP PF5020) almost always present *two* diagrams: a functional block diagram (the I²C/SPI map, regulator tree as black boxes) and a separate **power-rail / sequencing diagram** showing rails as horizontal busses with each load tapping off, and an associated **timing strip** (a row of t‑aligned step waveforms) labelling enable-to-PG delays. This separation is exactly the pattern co-circuit should adopt.

### A2. RF system block-diagram conventions

RF block diagrams are the most stylised in electronics and have hard, well-understood conventions taught by Pozar (*Microwave Engineering*), Razavi (*RF Microelectronics*), and Hayward (*Experimental Methods in RF Design*). ADI's RF reference diagrams (AD9213, ADF4368, ADAR1000, HMC-series) consistently follow these and they are worth mirroring exactly.

**Canonical RF symbols**
- **Amplifier** — equilateral triangle pointing in the direction of forward gain. Variants: "LNA" labelled inside or next to the triangle, "PA" for power amplifier, "VGA"/"PGA" for variable-gain. Two-triangles-back-to-back = bidirectional driver/buffer. A small letter `A` with subscript is common.
- **Mixer** — circle with an internal `×` (multiplication). Three ports: RF (typically the side), LO (the bottom or top stub), IF (the opposite side). Always label `RF`, `LO`, `IF` near each port, and always annotate the LO frequency next to the LO arrow (e.g., `LO = 2.4 GHz`). For an I/Q mixer, draw two mixers stacked with a `90°` block in the LO path.
- **Local oscillator / VCO** — circle with `~` inside, sometimes annotated `VCO`, `XO`, `TCXO`, `OCXO`. PLL synthesisers are drawn as a small block (phase detector + loop filter + divider) with an arrow to the VCO output.
- **Filter** — rectangle with the band shape sketched inside (a small mini–response curve): low-pass = falling slope at right, high-pass = rising slope at left, band-pass = a bump, band-reject = a notch. The text labels `LPF/BPF/HPF/BRF` plus the centre/cutoff freq (e.g., `BPF 2.4–2.5 GHz`). SAW/BAW filters are sometimes drawn with a small acoustic transducer glyph but most reference designs just use a labelled rectangle.
- **Attenuator** — rectangle with `dB` label (`-3 dB`, `0–31 dB step`) or a triangular pad symbol. Variable attenuators show a diagonal arrow through the box.
- **Coupler / directional coupler** — two parallel lines with arrows or a stylised dual-rectangle; label coupling factor `-10 dB`, isolation, etc.
- **Power splitter / combiner** — Y or T shape, sometimes labelled `÷2` for a Wilkinson. Quadrature hybrids use a square with the 0/90 outputs annotated.
- **Circulator / isolator** — circle with a curved internal arrow showing the rotation direction; three ports for circulator, two for isolator.
- **Switch (RF)** — schematic-style SPDT/SPnT inside a rectangle, with control lines coming in from the side.
- **Antenna** — the canonical "Y" or "loop" symbol at the edge of the board outline; for phased arrays, an array of these is drawn as a row of small Y's labelled with element number.
- **ADC / DAC** — labelled rectangle, often with a stepped-staircase glyph inside; sampling rate annotated near it (`AD9213: 10.25 GSPS`).

**Cascade and layout**
- RF chains read **left → right** (transmit) or **right → left** (receive). Many ADI diagrams put TX and RX on the same page with the antenna on the right, splitting into `RX↓` (top) and `↑TX` (bottom) at a T/R switch or circulator.
- LOs are drawn **from above** (above the mixer with the LO arrow coming down) — this is a near-universal convention, and you should enforce it. Synthesisers/PLL blocks live on their own row above the signal-flow row, with thin LO-distribution lines snaking down to each mixer they drive.
- IF stages are conventionally drawn with the IF frequency labelled in-line (`IF = 70 MHz`) and any IF gain/filter blocks placed in the same row.
- **Heterodyne / superhet receiver** (the textbook block-diagram shape): Antenna → preselect BPF → LNA → image-reject filter → mixer (with LO above) → IF BPF → IF amplifier → demodulator/ADC. Co-circuit should recognise this canonical sequence and lay out detected matches in this exact order even if the source data is unordered.
- **I/Q (zero-IF / direct conversion)**: one mixer becomes two stacked, with a 90° block in the LO branch; the two outputs run parallel through identical LPF + VGA + ADC paths labelled `I` and `Q`.
- **Phased arrays** (e.g. ADAR1000/ADAR2001 reference): each element column has its own LNA → phase shifter → VGA → combiner; columns are stacked vertically and merge into a single sum line at the right. Beamformer ICs are typically drawn as a tall rectangle containing the per-element internal chain.
- **Differential / balanced lines**: drawn as two parallel lines kept close together, often shaded as a single thick "ribbon" or wrapped in a tinted bracket; label `LO+/LO-` at the ends. The Pozar/Razavi convention treats baluns as a labelled rectangle (or transformer symbol) that splits a single-ended port into a differential pair.

**Frequency annotation** is part of the diagram itself: every signal segment between symbols in an RF chain should be labelled with its centre frequency, and gain/NF/IP3 cascade tables are often placed in a strip below the diagram (this is the standard "Friis-cascade" presentation in ADI app notes — co-circuit should support a table-strip overlay if RF metadata is present).

### A3. Software-architecture diagram conventions as inspiration

The most useful idea from software is **C4** (Simon Brown's model: System Context → Container → Component → Code) — four nested *levels of zoom*, only some of which you use for any given audience. Three lessons translate directly:

1. **Progressive disclosure.** Don't try to draw everything on one diagram. Pick a level (context / subsystem / detail) per page. Most boards only need 2 levels — a "context" view (the board's external interfaces + its top-level chunks) and a "container" view (each chunk expanded). The "code level" never applies; that's the schematic.
2. **Audience per page.** A context diagram is for the firmware/system owner reviewing the bring-up plan; a container diagram is for the EE doing the schematic review; a power-tree diagram is for the power-integrity reviewer. Each should answer one question.
3. **Notation-agnosticism is a feature**, not a bug. C4 explicitly tells you to use whatever shapes/colours you want as long as you legend them. Your tool should auto-emit a small legend in the SVG margin.

UML deployment diagrams and ArchiMate are less useful — they're heavy and oriented toward classes/services. But ArchiMate's **layered colour-banding** (each layer is a horizontal stripe with a consistent tint) is a great pattern for a power diagram where rails are visualised as coloured horizontal stripes.

The mapping for hardware is essentially:

| C4 level | Hardware equivalent |
|---|---|
| System Context | Board in its enclosure: connectors, antennas, host PC, mating boards |
| Container | Top-level functional blocks: MCU, PMIC, radio, sensors |
| Component | Inside one block: e.g. the regulator tree inside the PMIC, or the LNA→Mixer→IF chain inside the radio |
| Code | The schematic itself (skip) |

### A4. Which style fits which domain — concrete guidance

| Board type | Primary diagram style | Reading direction | Special features |
|---|---|---|---|
| MCU + peripherals | Hub-and-spoke with MCU centred; buses as labelled fat lines fanning out; expansion connectors as edge-stubs | Top-down or radial | Group by bus (I²C, SPI, USB); show protocol with colour |
| MCU carrier/baseboard | Two-page: power-tree + functional. Functional shows mating connectors prominently as "edges" | LTR for signal, TTB for power | Treat mezzanine connector as a board-edge object |
| Analog/RF daughterboard | Cascade left-to-right; mating connector at the left (towards host); RF connector at right (towards antenna) | LTR (signal flow) | LOs from above; annotate frequencies |
| RF frontend (TR module) | Cascaded TX (top) + RX (bottom) merging at T/R switch | LTR with antenna at right | Circulator/switch symbol; shared LO; PA bias separately |
| RF baseband board | Two-row: digital row (FPGA/SoC + memory + clocks) on top; mixed-signal row (ADC/DAC + clock distribution) on bottom | LTR | Show clock distribution explicitly as its own sub-page |
| Pure power board | Power-tree only; sources at top, loads at bottom, rails as horizontal busses | TTB | Sequencing arrows + timing strip |

The current compass layout is a special case of the MCU-with-peripherals view. Keep it as a *style*, but it should not be the default for the other four cases.

### A5. Specific visual conventions worth picking up

- **Power rail nomenclature**: standardise on `<name>_<voltage>` where the voltage is in millivolts or formatted (`VDD_3V3`, `VBAT_LI`, `+12V_SYS`, `VCC_RF_5V0`). Use this both as the net name and the label. Adopt the IEEE-ish convention of `VDD` for digital supplies, `AVDD/AVCC` for analog, `VBAT/VSYS/VIN` for raw inputs.
- **Visually distinguishing rails**: use **colour for voltage band** (e.g., red = >5 V, orange = 3.3–5 V, yellow = 1.8–3.3 V, green = <1.8 V, blue = negative) **and line-thickness for current** (>3 A = thickest). Don't try to encode both rail identity and voltage in the colour — pick one. The hue scheme above mirrors several power-supply textbook conventions and works well on white SVG.
- **Power sequencing**: prefer the **annotated block diagram + timing strip** style (the TI TPS6594 datasheet pattern). On the block diagram, draw `EN` and `PG` as thin dashed lines with arrowheads connecting regulator outputs to the next regulator's enable input. Below the block diagram, render a horizontal timing strip with each rail as one row, vertical guide-lines at sequence steps, and annotations `t_d1=2ms` on each gap. This dual representation is more readable than a state-machine and faster to scan than pure timing.
- **Ground**: at the block-diagram level you almost never need to draw GND wires — only show GND when it's a *signal* distinction (chassis vs analog vs digital, or a star-point). When you do show it, use the IEC ground triangle and an explicit AGND/DGND/CGND label.
- **Differential pairs**: render as a tightly-spaced parallel pair, or as a single fat line tagged `diff`. Always label with the pair name and an impedance if it matters (`USB_HS, 90Ω`, `MIPI CSI, 100Ω`).
- **Buses**: collapse to a single thick line with a slash + width (`/8`, `/32`). For typed protocol buses, render the protocol name as the line label (`I²C @ 400 kHz`, `SPI Mode 0`, `QSPI`, `USB 2.0 HS`). Don't show the constituent wires at this level — that's a schematic responsibility.
- **Protocol tagging by colour**: I²C = teal, SPI = orange, UART = grey, USB = green, CAN = purple, PCIe = magenta, MIPI = cyan, audio I²S = brown. Keep colours muted; use saturation for emphasis on the current diagram's "subject" bus.
- **Ratings on the diagram**: only annotate where it's load-bearing for understanding. On a power diagram, annotate every rail with `V, I_max`. On a signal diagram, annotate impedances on impedance-controlled nets and frequency on RF nets. Avoid clutter — the schematic carries everything else.
- **Test points / "magic pins"**: draw as a small filled-circle stub on the parent block with a `TP##` label. For probe-only pins, use an open circle.
- **Line crossings**: use the **jump-over arc** (semicircle) for non-connected crossings; use a filled dot for junctions. Avoid bare crossings entirely — both ELK and yEd's orthogonal router default to jump-arcs and it's the easiest convention to read.
- **Hierarchical sheet symbols / off-sheet refs**: borrow KiCad's vocabulary directly — input-pin, output-pin, bidirectional-pin, and tri-state pins have distinct shape outlines (pentagon/chevron/double-chevron). For multi-page SVG output, render off-page references as small flag glyphs with the destination page number.
- **Black-box vs. expanded**: a block is black-box when its internals are *not* on this diagram. Visually: a black-box block gets a small `[+]` glyph in the upper-right corner indicating "expandable" (interactively, click to open the sub-page; in static SVG, `<a xlink:href="…">`). An expanded block is drawn as a rounded rectangle *containing* its child blocks with a tinted background.
- **Frequency / timing annotations**: place inline along the wire near the destination port (`fc=2.4 GHz`, `t_setup=5ns`). For RF cascade tables, render a strip table below the diagram aligned to each stage.
- **Edges (board-edge connectors and external interfaces)**: treat board-edge objects specially — draw them on the literal edge of the diagram's bounding rectangle, with pin labels facing outward. Mate connectors on daughterboards should always be on the same edge (typically left/bottom).
- **Enable / power-good cascades**: dashed line with an open arrowhead; label `EN` or `PG` at the destination. PG chains often form a directed acyclic graph and should be auto-laid-out as a Sugiyama-style DAG on the power diagram.

---

## Part B — Algorithmic / Layout

### B1. Graph drawing algorithms — what fits a block diagram

| Algorithm family | Strength | Weakness | Verdict for co-circuit |
|---|---|---|---|
| **Sugiyama layered** (Graphviz `dot`, ELK Layered, Dagre, rust-sugiyama) | Excellent for DAGs and signal flow; produces canonical LTR/TTB layouts; handles ports cleanly when extended | Assumes a flow direction; suffers when the graph has many cycles or is highly hub-centric | **Primary choice** for functional diagrams and power trees |
| **Force-directed** (Fruchterman–Reingold, Kamada–Kawai, FM³) | Good for organic / undirected exploration; few inputs needed | Non-deterministic; can twist; produces "blob" layouts that engineers find unreadable; ignores ports | Avoid for the final diagram; usable as an *initial* layout for clustering visualisation only |
| **Orthogonal** (Tamassia topology-shape-metrics; yEd's `OrthogonalEdgeRouter`) | Right-angle edges, looks like a schematic; respects ports | Computationally heavy; harder to implement from scratch; can produce unintuitive node order without a layering pre-pass | Use the **routing** half (orthogonal connector A* on a visibility grid) on top of Sugiyama placement |
| **Hierarchical / compound** (ELK with nested sub-graphs) | Handles clusters and sub-diagrams natively | Complex API | Worth borrowing the *concept* (compound nodes) even if you don't import ELK |
| **Compass / region-constrained** (your current layout) | Predictable; matches reader expectations for MCU boards | Brittle when categories don't fit; doesn't handle long signal chains | Keep as one named style (`(layout-style compass)`) |
| **PCB-style force placement** (Quinn–Breuer 1979) | Optimises wire length; classical EDA | Not visually canonical; uses overlap penalty rather than ports | Skip |

**Recommendation**: build the engine as a **Sugiyama-with-ports placer + orthogonal A\* router**, with a small set of additional named styles (compass, RF-cascade, power-tree) that are essentially constraint presets on top of that base.

### B2. The Sugiyama framework in detail

Sugiyama, Tagawa & Toda's 1981 algorithm has four canonical phases (ELK and Dagre both subdivide into 5–6, but the structure is the same):

1. **Cycle removal.** Convert the directed graph to a DAG by reversing a minimum feedback arc set. In Rust, `petgraph::algo::greedy_feedback_arc_set` is good enough; `rust-sugiyama` uses exactly this. The reversed edges are later rendered with a dashed style or reverse arrowhead so the engineer can tell. *Pitfall*: I²C and SPI nets have bidirectional traffic — model them as undirected edges and resolve direction with port roles (clk → in, data → bidi) rather than letting the cycle-breaker pick arbitrarily.
2. **Layer assignment.** Assign each node to an integer layer such that all edges go from lower to higher layer. Options: longest-path layering (fast, wastes width), Coffman–Graham (balances width), or **Gansner et al.'s network-simplex** (minimises total edge length). The network-simplex method is what Graphviz `dot` uses and what `rust-sugiyama` borrows from the same paper; it's the right default. *Pitfall*: hubs with very high degree (an MCU with 100 connections) drag many nodes into adjacent layers — counter this with `(layer-rank N)` annotations and a configurable max-layer-width.
3. **Vertex ordering within each layer.** This minimises crossings. Both **barycentric** (Sugiyama original) and **weighted median** (Gansner) heuristics work; both are sweeps that converge in 20–24 iterations typically. Combine with a **transpose** step (swap adjacent vertices if it reduces crossings) after each sweep. *Pitfall*: with ports, you must minimise *port-crossings* not just node-crossings — barycentre on the port positions, not node centres, as in Schulze et al.'s "Drawing layered graphs with port constraints".
4. **Coordinate assignment.** Brandes & Köpf's "Fast and Simple Horizontal Coordinate Assignment" is the standard; it produces aligned, low-bend results and is what ELK uses. The y-coordinate is just `layer * spacing`; x-coordinate comes from the alignment algorithm with priority on long edges (so they stay straight).

After these four phases, you do **edge routing** (often counted as a 5th phase) — for our purposes, orthogonal Manhattan routing on a coarse grid (see B9).

### B3. Port-aware layout

Standard Sugiyama places nodes as points; real block diagrams have edges entering at *specific positions on the perimeter*. This matters because (a) flow looks wrong if a "data out" port at the bottom of an IC ends up routed from its top, and (b) ports impose ordering constraints within a layer.

**ELK's approach** (the reference): nodes have a port-side constraint (`FIXED_SIDE`, `FIXED_ORDER`, or `FIXED_POS`) and the barycentre heuristic operates on port positions. Northern/southern ports are handled by a pre-/post-processor that may insert dummy intermediate layers so that an edge entering a north port crosses cleanly through a "turn" dummy. For co-circuit, the practical guidance is:

- Every block-instance should declare its ports with a *side hint* (`west` for inputs, `east` for outputs is the LTR default; `north` for clocks/LO, `south` for power).
- Inside vertex-ordering, sort the ports on each side by their average neighbour barycentre, so the connections fan out smoothly.
- For long edges that need to enter on the "wrong" side, insert a single dummy node in an adjacent layer (this is the trick the port-constrained Sugiyama paper uses).

The Schulze, Walter & Nöllenburg paper (*Drawing layered graphs with port constraints*) explicitly targets cable-plan-style diagrams which are exactly your domain; it produced 10–30% fewer crossings than Kieler. Worth reading before implementing.

### B4. Hub-and-spoke vs. flat layout

Your existing convention — ICs/connectors/transistors as boxes; passives drawn inline on the wires between them — is the **collapsed-passive** model. It's the right default. Layout consequences:

- A "hub" is a node that participates in the layered graph and gets a coordinate.
- A "spoke" passive is rendered as a glyph on an *edge* (R as a zigzag, C as parallel lines, L as a coil) — it doesn't get its own grid cell. Place spoke glyphs at fixed normalised positions on the routed polyline (e.g., 50% if one, 33%/66% if two).
- **Promote a spoke to a hub** when any of: (a) it has > 2 terminals (impossible for a simple R/C/L, but trans-impedance Rs, sense resistors with Kelvin connections, or filter blocks often do); (b) it has annotations the user wants prominent (SAW filter, crystal); (c) it's marked `(role critical)` or `(diagram-promote)` in the source.

This means the layout engine sees a *simplified graph* in which spokes are erased and their net contribution is preserved as edge attributes (resistance, capacitance, label). Generate this simplified graph before layout, not after.

### B5. Auto-clustering

When the section/group annotations are absent or coarse, fall back on graph community detection. Two viable algorithms:

- **Louvain** (Blondel et al. 2008): greedy modularity maximisation; fast (O(n log n) typical); the canonical default. Available in Rust via crates that wrap `petgraph` graphs.
- **Leiden** (Traag, Waltman & van Eck 2019): refinement of Louvain that *guarantees connected communities* and produces higher-quality partitions; ~30% slower in practice. Up to 25% of Louvain's communities are badly connected and ~16% disconnected — for a hardware netlist this matters because a "community" that's split across two disconnected subgraphs is meaningless. **Use Leiden as the default** if you can.

Beyond modularity, two domain-specific clusterings are more valuable than blind community detection:

- **Power-domain clustering.** Compute, for each block, which power rails it consumes. Cluster blocks that share the same set of rails. This usually recovers the "analog island", "1V8 core", "5V load" partitions automatically.
- **Bus-domain clustering.** Cluster blocks that all sit on the same I²C/SPI bus segment. This typically recovers "sensor cluster on I²C-2", "off-board QSPI flash", etc. Effectively, treat each bus net as a hyperedge and partition the bipartite block-bus graph.

A hybrid that works in practice: run Leiden, then **post-process** by merging any communities that share > 75% of their power rails, and splitting any community whose induced subgraph has > 1 connected component. This handles the pathological cases.

### B6. Signal-flow detection

To decide a default flow direction, the layered placer needs a DAG. Sources of direction, in priority order:

1. **Declared port direction** on the instance type (input/output/bidi/power) — by far the strongest signal. Treat any in→out path as a directed edge.
2. **Role metadata** (`(role clk)`, `(role reset)`, `(role data)`) — for example, clocks flow from oscillator/PLL outputs to consumers.
3. **Protocol metadata.** For master/slave protocols (SPI, I²C), the master is the source. Detect via which device has the `CLK`/`SCL` output role.
4. **Topological hints from instance type.** Anything labelled `regulator/source/battery` is a source; anything labelled `load/MCU/sensor` is a sink for power but a source for sensor data.
5. **Bidirectional fallback.** For genuinely bidirectional buses (parallel memory, ULPI, RGMII), pick the direction that minimises the feedback arc set; this is what Sugiyama's cycle-removal already does.

For RF specifically, mark `antenna` instances as flow endpoints (sink for TX, source for RX), and propagate the flow direction from there. Mixers should have a hard-coded port role table: RF port is the "side" (data direction), LO is the "control" (from above), IF is "downstream".

### B7. Power-domain & power-tree extraction

Given the netlist, the power tree is recovered as follows:

1. **Identify power producers**: instances with port role `power-out` or whose type is `battery|regulator|ldo|buck|boost|charger|pmic`. Identify power consumers: any port marked `vdd|vcc|vbat|power-in`.
2. **Build a directed graph** where each power net is a node, and each regulator is an edge from its `Vin`/`VBAT` net to its `Vout` net. Each load block contributes edges from each of its supply pins back to its corresponding rail node (or, more usefully, the rail node has all its consumers as out-edges).
3. **Root the tree** at the source(s) (battery, USB, DC-jack, board-edge VBUS). Walk BFS to assign tier numbers (tier 0 = raw input, tier 1 = primary buck, tier 2 = LDO downstream, etc.).
4. **Detect sequencing relations** by looking at `EN` and `PG` nets: any net whose name matches `EN_*|*_EN|PG_*|*_PG|nRST_*` and which connects a regulator output (or a GPIO of a sequencer) to another regulator's enable pin is a sequencing edge. Build a second DAG of sequencing edges; this is what the timing strip is generated from.
5. **Per-rail load summing**: if instances declare `(port name "VDD" power-in (current 50mA typical))`, you can auto-annotate each rail with `ΣI_typ / ΣI_max`. This is a high-value lightweight feature.

The result is two structures: a **power tree** (for the block-diagram half of the power page) and a **sequencing DAG** (for the timing/PG-chain half).

### B8. Practical layout engines — build vs. buy

| Engine | Language | Suitability | Notes |
|---|---|---|---|
| **Graphviz** (`dot`, `neato`, `fdp`, `sfdp`) | C | Battle-tested; emits SVG | Shell out, parse the SVG; limited port support; awkward to constrain |
| **ELK / ELK Layered** | Java | Best-in-class layered + ports + orthogonal routing | Heavyweight; not Rust; transpiled `elkjs` (JS) usable via embedded V8/Deno, but adds a runtime |
| **yFiles** | Java/JS | Commercial; gold-standard quality | License cost; not appropriate for an OSS tool |
| **Mermaid / mxGraph / draw.io** | JS | Easy to embed | Cycles, no real port support, layouts are crude |
| **rust-sugiyama** | Rust | Pure-Rust Sugiyama (Gansner network-simplex + median heuristic + Brandes–Köpf coord assignment) | The right starting point; lacks ports |
| **dagre-rs** | Rust | Port of Dagre.js | Similar capabilities, less actively developed |
| **layout-rs** | Rust | Includes a DOT parser and SVG backend with Sugiyama | Direct SVG output — useful for prototyping |

**Opinionated recommendation**: do not adopt ELK. The JVM dependency is wrong for a Rust tool, and elkjs forces a JS runtime which adds enormous surface area. Build your own pipeline using:

- `petgraph` for graph representation and FAS / topological sort
- `rust-sugiyama` (or roll your own based on the Gansner paper) for layering and coordinate assignment, extended with port awareness following the Schulze et al. paper
- A bespoke orthogonal A\* router on a visibility/grid model (the Wybrow–Marriott "Orthogonal Connector Routing" paper, Stuckey et al., is the right reference) — this is < 1000 lines and gives you the visual quality
- Direct SVG emission via the `svg` crate or just `format!` — there's no benefit to a DOM abstraction at this scale

This is roughly the architecture of yFiles and ELK reduced to the parts you actually need.

### B9. Practical heuristics for the SVG/Rust implementation

A handful of small things go a long way:

- **Snap everything to a fixed grid** (10 px or `5 mm`-equivalent). Edges, ports, node corners. Orthogonal routing is dramatically easier on a grid.
- **Lay out nodes first, then route edges.** Don't try to do both simultaneously — the orthogonal router can usually find a good path post-hoc.
- **Channel routing.** Reserve horizontal/vertical channels between layers for bus routing; bias edges to share channels if they go to the same destination layer. This is the dominant trick in yFiles' orthogonal router.
- **Bus bundling.** If five wires go from MCU to the same connector and they share a protocol tag, route them as one fat line with a `/5` label; don't draw five parallel lines.
- **Label placement**: place edge labels at the centre of the longest horizontal segment (or vertical, whichever is longer). For port labels, place them just inside the node next to the port glyph.
- **Long-edge straightening**: after Brandes–Köpf, do a final pass that nudges dummy-node x-coordinates to keep multi-layer edges vertically aligned.
- **Power producers at top, consumers at bottom.** Hard-code this for power-tree pages; it matches the textbook convention. Rails span horizontally as a "bus bar"; consumers tap off downwards.
- **MCU at the centre or top** for functional pages, depending on whether the MCU has external host/USB (then it's centre) or is the host (then top).
- **Pagination.** Multi-page SVG with internal `<a xlink:href="#page-N">` links works in every modern viewer. Provide a small sitemap thumbnail in each page corner.
- **Determinism.** Sort all collections before layout passes. SVG output should be byte-identical on rerun so it's reviewable in Git diffs.

### B10. The two-diagram split — opinionated specifics

**Power & sequencing diagram.** A single page divided into three horizontal bands:

1. **Top band: source rails.** Battery / USB-VBUS / DC-jack as labelled rectangles on the left edge; primary regulators (boost/buck) downstream; their outputs are short horizontal stubs feeding into the bus bars below.
2. **Middle band: rail bus bars.** Each rail is a thick horizontal coloured line spanning the full page width; the rail name and voltage are at the left, and `ΣI_max` at the right. Secondary regulators (LDOs derived from primary rails) are drawn as boxes that tap the parent rail from above and feed a new rail bar below them.
3. **Bottom band: loads.** Each load tap from a rail with a labelled short vertical drop; loads grouped by domain. Include a per-rail load summation (auto-computed from `(current)` annotations).

Overlay: dashed enable/PG arrows from each regulator's `PG` to the next regulator's `EN`. Below the entire diagram, a **timing strip** with each rail as one stair-step row, ordered by sequence number, with `t_d` labels between transitions.

For boards with **multiple power domains** (e.g., a daughterboard with always-on + main + RF domains), split the page into vertically-stacked sub-frames, one per domain, each with its own bus bars and a clear domain label on the left margin.

**Functional / signal diagram.** Strategy by board type:

- **MCU board**: a context layer at the top showing external interfaces (USB, debug, antenna, mate connector) as edge stubs; the MCU as the centre block; peripherals fanned out below grouped by bus.
- **RF daughterboard or RF frontend**: **left-to-right cascade** as the primary layout; LO/clock distribution as a horizontal row above the main chain; mate connector at the left, antenna at the right; gain/NF cascade table (if RF metadata present) as a strip below.
- **RF baseband**: two parallel rows — digital row on top (FPGA + memory + clock distribution), analog row on bottom (ADC/DAC + filters + analog conditioning); converters span both rows.
- **Carrier baseboard**: the mate connector is the dominant "central spine" — draw it as a tall rectangle in the middle; functional blocks on either side.

For RF specifically: **always left-to-right**; **LOs always from above**; **differential pairs always rendered as parallel pairs**, never collapsed to a single line (because the engineer needs to see the balance). For phased arrays, stack element chains vertically and combine on the right.

### B11. DSL extensions for co-circuit — opinionated proposal

Rules of thumb for what's worth adding:
- *Auto-infer if you can*; only ask the user to annotate when inference would be brittle or wrong.
- *Override > infer*: any annotation must be a soft override of inference, not a mandatory input.
- *Style hints separate from semantic info*: `(role clk)` is semantic; `(rail-color "VDD" red)` is style. Keep them in different namespaces.

**Worth adding (high value):**

```scheme
;; Diagram pagination — explicit page selection
(diagram-page "power"
  :style power-tree
  :includes (regulators loads rails))

(diagram-page "functional"
  :style cascade
  :includes (mcu peripherals connectors))

;; Signal flow declaration — when port-direction inference fails
(signal-flow antenna lna mixer if-filter adc)   ; canonical RF chain order

;; Layout hints — soft constraints, not absolute positions
(layout-hint :left-of "mcu" "regulator")
(layout-hint :same-rank "imu" "magnetometer")
(column-rank "antenna" 0)
(column-rank "adc" 4)

;; Block promotion — force a passive to be a hub
(diagram-promote "X1")        ; the crystal becomes a labelled box, not a glyph
(diagram-collapse "U7")       ; the regulator collapses into its parent rail

;; Group style override per section
(group-style "rf-chain" cascade)
(group-style "sensors" cluster)
(group-style "power" tree)

;; Power-tree explicit declaration — only when inference is wrong
(power-tree
  (battery "BAT") -> (buck "U1" :rail "VSYS_3V8")
  (buck "U1") -> (ldo "U2" :rail "VDD_1V8")
  (buck "U1") -> (ldo "U3" :rail "VDD_AVDD_1V8" :enable (after "U2" :delay-ms 2)))

;; Sequencing — declarative timing facts that drive the timing strip
(power-sequence
  ("VSYS_3V8" :order 0)
  ("VDD_3V3"  :order 1 :after "VSYS_3V8" :delay-ms 1)
  ("VDD_1V8"  :order 2 :after "VDD_3V3"  :pg-from "U1"))

;; Style — pure visual
(rail-style "VDD_RF_5V0" :color "#ff6b6b" :weight 3)
(protocol-style i2c :color "#0aa" :line-style solid)
(diagram-legend "RF block diagram, rev B")

;; Frequency annotations for RF
(net "RF1" :freq "2.4 GHz")
(net "IF1" :freq "70 MHz")
(net "LO1" :freq "2.33 GHz")
```

**Auto-inferred — do not require user annotation:**

- Port direction → from instance type definitions in the symbol library
- Power producer/consumer → from port roles (`power-in`/`power-out`)
- Bus/cluster membership → from net connectivity (Leiden + power-domain hybrid)
- Default flow direction → from topological sort of declared port directions
- Default rail colours → from voltage band (red/orange/yellow/green/blue scheme)
- Cascade detection for RF → from sequence of (amplifier|filter|mixer|attenuator) connected in series

**Avoid adding (low value, brittle):**

- Pixel-perfect coordinates — defeats the purpose of an automatic layout
- Per-edge waypoint lists — let the router decide; if the result is wrong, fix the router, not the DSL
- Colour for every individual net — colour by *kind* (rail/protocol/role), not by net

**Two final structural additions that pay for themselves:**

1. **`(import-as "u1" :symbol stm32n6 :ports …)`** — a per-instance port-side override. Lets the user say "this MCU's external memory bus pins should go *east* in the diagram even though I declared them as bidi". Without this, port-side inference fails for ICs with hundreds of pins.

2. **`(diagram-cut "label" :ports …)`** — declare a *cut*, a virtual page boundary. Anything on the other side of the cut renders as an off-page reference glyph. Use this to manually split a too-large functional diagram into two SVG pages without restructuring the source.

---

## Summary of recommendations

1. **Replace the single compass layout with a styled pipeline**: parse → cluster → choose style per page → place (Sugiyama + ports) → route (orthogonal A\*) → render SVG.
2. **Always emit two diagrams per design**: a power-and-sequencing page (TTB, rails as bus bars, timing strip) and a functional page (LTR or radial depending on board archetype).
3. **For RF**, follow the textbook conventions literally: LTR cascade, LOs from above, triangles for amplifiers, circle-×-circle for mixers, mini-response curves inside filter rectangles, frequency labels on every segment.
4. **For algorithms**, build on Sugiyama with port-awareness (Schulze et al.) and Brandes–Köpf coordinate assignment; do orthogonal routing with A\* over a visibility grid (Wybrow & Marriott). Use Leiden + power-domain hybrid for clustering when annotations are absent.
5. **In Rust**, base the implementation on `petgraph` + `rust-sugiyama` (or a from-scratch Sugiyama) + a bespoke orthogonal router. Do not adopt ELK or yFiles.
6. **DSL extensions**: add `diagram-page`, `signal-flow`, `power-tree`, `power-sequence`, `column-rank`, `layout-hint`, `group-style`, `diagram-promote`, `rail-style`, `protocol-style`, and per-net `freq` annotations. Everything else should be inferred.
7. **Lean on C4-style progressive disclosure**: every block can be a black-box on one page and expanded on a sub-page; emit interactive multi-page SVG with `<a xlink:href>` between pages and a small page-map in the margin.
8. **Determinism, gridding, and orthogonal-arc jumps** are the three cheap heuristics that produce the biggest readability gains.

These choices give you a tool whose output is recognisable as "what a hardware engineer would draw" rather than "what a generic graph-drawing library produced".