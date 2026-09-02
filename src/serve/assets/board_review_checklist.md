## Section 1 — Requirements & Specification Review

- [ ] **1.1** Design-intent / requirements document exists, is version-controlled, and is the reference for this review.
- [ ] **1.2** Operating input voltage range (min/nominal/max, including transients) defined for every power input.
- [ ] **1.3** Total and per-rail current/power budget defined at worst case.
- [ ] **1.4** Operating and storage temperature ranges defined (ambient, not just junction).
- [ ] **1.5** Component temperature grade matches spec: commercial (0–70 °C), industrial (−40–85 °C), extended (−40–105/125 °C), or automotive AEC-Q (−40–125/150 °C). *(Major.)*
- [ ] **1.6** Environmental requirements defined: humidity, condensation, shock/vibration, altitude, ingress (IP) rating, conformal coating.
- [ ] **1.7** Altitude/derating: IEC 60664-1 insulation coordination applies up to 2000 m; above that, multiply clearances by the standard's altitude correction factor. Per Infineon's IEC 60664-1:2020 note, the factor is **1.48 at 5000 m** ("Altitude correction factors is 1.48 from Table 4, then the final clearance is calculated to be 1.5 mm × 1.48 = 2.22 mm"). *(Major for mains/HV.)*
- [ ] **1.8** Regulatory/compliance targets identified: FCC/CE emissions (CISPR 32/CISPR 25 automotive), immunity (IEC 61000-4-2 ESD, -4-4 EFT, -4-5 surge), safety (IEC 62368-1 replacing 60950/60065; IEC 61010 lab; IEC 60601 medical; UL listing).
- [ ] **1.9** ESD/surge/transient immunity levels quantified (e.g., ±8 kV contact / ±15 kV air per IEC 61000-4-2; surge in kV/amps).
- [ ] **1.10** Functional-safety / reliability targets defined where applicable (ISO 26262 ASIL; IEC 61508 SIL; DO-254 avionics; target FIT/MTBF).
- [ ] **1.11** Derating standard chosen and stated (NASA EEE-INST-002, MIL-HDBK-1547, ECSS-Q-ST-30-11, or internal) so passive/semiconductor checks have a numeric basis.
- [ ] **1.12** Production volume, target unit cost, and expected product service life (years) stated.
- [ ] **1.13** IPC performance class target chosen (Class 1 general, Class 2 dedicated service, Class 3 high-reliability). Per IPC's John Perry, Class 3 is for products where "continued high performance or performance-on-demand is critical, product downtime cannot be tolerated, [and the] end-use environment may be uncommonly harsh." *(Major.)*
- [ ] **1.14** Enclosure/mechanical interface (board outline, mounting holes, connector positions, keep-outs, max heights) captured from a mechanical drawing.

---

## Section 2 — Schematic Review (General)

- [ ] **2.1** ECAD ERC is 100% clean; every waived error is individually inspected and signed off as a valid toolchain quirk. *(Critical.)*
- [ ] **2.2** No unconnected/floating pins except intentional (documented) ones. Every unused input has a defined logic state.
- [ ] **2.3** No accidental shorted nets or duplicate net names merging unrelated nets.
- [ ] **2.4** Net naming consistent, descriptive, unique; a labeled net is actually used elsewhere.
- [ ] **2.5** All schematic symbol pin numbers verified against datasheet/interface spec (especially not-yet-board-proven parts). *(Critical.)*
- [ ] **2.6** Schematic symbol matches the chosen component package/variant.
- [ ] **2.7** Hierarchical/off-page connectors match across sheets (name + direction).
- [ ] **2.8** Cross-board cable pinouts verified (straight-through vs mirrored) against the mating board. *(Major.)*
- [ ] **2.9** Power-rail tree diagram present; every load fed by the correct voltage.
- [ ] **2.10** Power budget per rail computed at worst case with margin against each regulator's rating.
- [ ] **2.11** Power-sequencing requirements captured and satisfied.
- [ ] **2.12** Reference designators unique, sequential, consistent between schematic, layout, and BOM.
- [ ] **2.13** DNP/DNI parts clearly marked in schematic and BOM.
- [ ] **2.14** Test points placed on all power rails and key signals.
- [ ] **2.15** Revision/title block, date, change history present; schematic frozen and peer-reviewed before layout.
- [ ] **2.16** Errata sheets read for every major device; known silicon bugs designed around (e.g., "STM32: do not use JTRST pin as an I/O"). *(Major.)*
- [ ] **2.17** 0-Ω resistors / jumper links used for strap pins and isolation points to aid rework.
- [ ] **2.18** Schematic legible: no overlapping symbols/wires; 4-way junctions avoided or dotted; decimal points not lost.

---

## Section 3 — Per-Component Passive Checks

> For **every** passive that carries meaningful power, voltage, or precision, fill in the **Per-Passive Derating Template** (below).

### 3.1 Resistors
- [ ] **3.1.1** Power dissipation ≤ derated limit. NASA EEE-INST-002 general derating: operate at ≤60% of rated power at T1 (factor 0.6 film/composition; 0.5 general), derate linearly to zero power at the zero-power temp. *(Major.)*
- [ ] **3.1.2** Voltage across resistor ≤ lesser of **80% of rated max voltage** or √(P_derated × R). Critical for high-value resistors in **high-voltage dividers** (a single 0603 is often only rated 75–150 V). *(Critical for HV.)*
- [ ] **3.1.3** Pulse/surge energy within the part's pulse rating (inrush, discharge, snubber).
- [ ] **3.1.4** Tolerance and tempco appropriate for the function; tolerance stack-up analyzed for critical ratios.
- [ ] **3.1.5** Current-sense resistor uses a **Kelvin (4-terminal) connection**; sense taps route as a tight differential pair, out of the switching di/dt path. Per ADI, "Failure to properly Kelvin sense the current across the sense resistor is the most common cause of circuit malfunction in current mode power supplies and Hot Swap circuits." *(Major.)*
- [ ] **3.1.6** Current-sense self-heating controlled: PCB copper TCR (~3900 ppm/°C) can dominate a low-TCR shunt (5–50 ppm/°C); keep the shunt below ~85 °C at worst-case ambient; derate power above 70 °C per the curve.
- [ ] **3.1.7** Pull-up/pull-down values matched to bus capacitance and speed (see I²C, 4.6).
- [ ] **3.1.8** For harsh/humid/sulfur environments, anti-sulfur and moisture-resistant resistors specified.

### 3.2 Capacitors — ceramic (MLCC)
- [ ] **3.2.1** DC-bias derating: Class II (X5R/X7R) lose large capacitance under DC bias — X7R commonly 30–50%, X5R 40–60% at rated voltage, up to ~90% for high-K. Apply the "2×" rule: rated voltage ≥ 2× applied DC (≥10 V on 5 V, ≥25 V on 12 V). Verify effective capacitance at the operating point with the vendor DC-bias tool. *(Major.)*
- [ ] **3.2.2** NASA EEE-INST-002 ceramic voltage derating factor **0.60 at ≤110 °C** (for <10 V apps, styles CCR/CKR/CDR must be rated ≥100 V).
- [ ] **3.2.3** Use **Class I (C0G/NP0)** for timing/filter/PLL/oscillator load caps — never Class II.
- [ ] **3.2.4** Aging accounted for: per Johanson Dielectrics, "For X7R and X5R the loss is calculated at −2.5% per decade hour and for Y5V it is −7% per decade hour" (EDN cites X7R 2.5–3%, X5R 3–7% depending on manufacturer). Include a 20–30% aging margin on bulk MLCC.
- [ ] **3.2.5** Ripple current and self-heating within case-size limits (SMPS output caps).
- [ ] **3.2.6** Flex-crack protection: keep large MLCCs (≥1206) away from edges, mounting holes, connectors, and V-score/depanel zones; orient long axis parallel to the break; consider flex-termination parts. *(Major — cracked MLCC = latent short/fire.)*
- [ ] **3.2.7** HV MLCCs in series have balancing resistors if used above a single part's rating.
- [ ] **3.2.8** Microphonics/singing considered for Class II caps in audio / high-dV/dt nodes.

### 3.3 Capacitors — tantalum
- [ ] **3.3.1** Solid **MnO₂ tantalum derated to ≤50% of rated voltage**. Per Vishay Sprague, MIL-HDBK-217 "dictates the 50% voltage derating to achieve a 5 FIT to 15 FIT rate," because MnO₂ contains an internal oxygen source and "if the temperature rise occurs too quickly, a dangerous ignition event can be triggered." *(Critical — ignition/fire.)*
- [ ] **3.3.2** For rated voltages ≥35 V, apply even more derating (Vishay).
- [ ] **3.3.3** Polymer tantalum (benign open failure) may run at ~80–90%: derate 10% for ≤10 V, 20% for >10 V (Vishay).
- [ ] **3.3.4** Surge/inrush limiting: series resistance ≥0.1 Ω/V (NASA Grade 2) or ≥0.3 Ω/V (Grade 1), or an inrush limiter, where tantalums see low-impedance sources.
- [ ] **3.3.5** NASA space derating: solid tantalum **0.50 at 70 °C / 0.30 at 110 °C**; wet slug 0.60/0.40.

### 3.4 Capacitors — aluminum electrolytic
- [ ] **3.4.1** Voltage: Vdc + Vripple ≤ ~80–90% of rated (conservative design-margin practice; Nippon Chemi-Con notes alu caps have no DC-bias effect and voltage derating is minor for lifetime — temp/ripple dominate).
- [ ] **3.4.2** Lifetime via Arrhenius: life doubles per 10 °C reduction below rated temp (L = L₀ × 2^((Tmax−Tactual)/10)). A 105 °C/5000 h part gives 20,000 h at 85 °C, 80,000 h at 65 °C. Confirm calculated life ≥ service-life requirement at worst-case internal ambient + ripple self-heating. *(Major.)*
- [ ] **3.4.3** Ripple-current rating (at actual freq/temp, using the manufacturer's multipliers) ≥ applied ripple; ESR/self-heating checked.
- [ ] **3.4.4** Polarity correct; cold-start ESR/capacitance drop acceptable.

### 3.5 Capacitors — film & safety-rated
- [ ] **3.5.1** Film caps derated (NASA 0.60; common practice 50–80% by AC/pulse content); self-healing budget considered.
- [ ] **3.5.2** X-class line-to-line and Y-class line-to-ground on mains; agency ratings (X1/X2, Y1/Y2) match; Y-cap leakage current within limits.

### 3.6 Inductors / ferrite beads
- [ ] **3.6.1** Saturation current > peak inductor current at worst case (max load + ripple); DC-bias inductance roll-off checked on the vendor curve. *(Major.)*
- [ ] **3.6.2** RMS/thermal current rating > continuous current with acceptable temperature rise.
- [ ] **3.6.3** DCR loss and self-heating within thermal budget.
- [ ] **3.6.4** Self-resonant frequency above the operating/switching frequency for filter function.
- [ ] **3.6.5** Shielded inductor where H-field coupling is a concern; orientation minimizes coupling.
- [ ] **3.6.6** Ferrite bead impedance specified at the **actual noise frequency** (beads are only meaningfully resistive at high frequency; below their inductive region — characterized in ADI AN-1368 down to ~30 MHz for the example bead — they act as a high-Q inductor). *(Major.)*
- [ ] **3.6.7** Ferrite-bead DC-bias derating: rated impedance collapses with DC current. Per ADI AN-1368, "By applying just 50% of the rated current, the effective impedance at 100 MHz dramatically drops from 100 Ω to 10 Ω for the TDK MPZ1608S101A (100 Ω, 3 A, 0603)"; ADI recommends operating beads "at about 20% of their rated dc current." *(Major.)*
- [ ] **3.6.8** Ferrite-bead + decoupling-cap LC resonance checked. Per ADI, "LC resonant frequencies for typical bead filters are generally in the 0.1 MHz to 10 MHz range… additional damping is required to reduce the filter Q," else the filter shows gain (peaking). Add a damping RC (CDAMP + RDAMP). *(Major — rail ringing/instability.)*

### 3.7 Diodes / rectifiers / Schottky
- [ ] **3.7.1** Reverse voltage (PIV) derated: NASA general/rectifier/switching/Schottky **PIV factor 0.70**. *(Major.)*
- [ ] **3.7.2** Average forward current **0.50**; non-repetitive surge current **0.50**.
- [ ] **3.7.3** Junction temperature **0.80**, not exceeding Tj = 125 °C (or 40 °C below datasheet max).
- [ ] **3.7.4** Reverse-recovery/speed adequate for the switching frequency.
- [ ] **3.7.5** Schottky reverse-leakage vs temperature evaluated — leakage rises steeply with Tj and can cause thermal runaway in hot, high-reverse-voltage use. *(Major.)*
- [ ] **3.7.6** Vf drop and its power dissipation included in the thermal budget.

### 3.8 TVS / ESD protection
- [ ] **3.8.1** Reverse standoff voltage (VRWM) set **10–20% above** the line's max normal operating voltage. *(Major.)*
- [ ] **3.8.2** Max clamping voltage (VC) at the applied peak pulse current is **below the abs-max of every device on the protected line** — the check that actually protects the IC. VC ≈ VC(rated) − R_dyn×(IPP_rated − IPP_applied); IPP ≈ (Vsurge − VC)/Rsource. *(Critical.)*
- [ ] **3.8.3** Peak pulse power / IPP rating exceeds the required surge (matched to test waveform, e.g., 8/20 µs or 10/1000 µs).
- [ ] **3.8.4** Junction capacitance low enough not to distort the protected signal (low-C arrays for USB/HDMI/Ethernet).
- [ ] **3.8.5** Polarity correct: unidirectional for fixed-polarity DC; bidirectional for AC/differential.
- [ ] **3.8.6** Placed at connector/cable entry with minimal loop inductance to chassis/ground.

### 3.9 MOSFETs / BJTs
- [ ] **3.9.1** VDS margin: NASA power-MOSFET source-to-drain voltage **0.75** (worst-case DC+AC+transient). *(Major.)*
- [ ] **3.9.2** VGS margin: gate-source voltage **0.60**; gate never exceeds abs-max even with ringing; gate clamp where needed.
- [ ] **3.9.3** RDS(on) evaluated at the **actual VGS applied** (not the 10 V headline) and at hot Tj — losses recomputed.
- [ ] **3.9.4** Gate charge vs driver strength gives acceptable switching time/loss; gate resistor chosen for ringing vs speed.
- [ ] **3.9.5** **SOA** checked for any linear-mode/inrush/hot-swap/e-fuse operation, derated from the datasheet single-pulse/25 °C curve to actual Tc, VGS, and pulse width. *(Critical for hot-swap/e-fuse.)*
- [ ] **3.9.6** Avalanche/UIS rating adequate for unclamped inductive turn-off; avoid parts with >30% UIS degradation 25→125 °C.
- [ ] **3.9.7** Current **0.75**, power **0.60**, Tj **0.80** (NASA transistor derating).

### 3.10 Fuses / PPTC
- [ ] **3.10.1** Hold current > max normal current, trip current < downstream-damage current, both at worst-case ambient (PPTC hold current derates strongly with temperature).
- [ ] **3.10.2** Cartridge fuse current derated ~50% (NASA: 50% for 2–15 A; more for small fuses) plus 0.2%/°C above 25 °C.
- [ ] **3.10.3** Voltage rating ≥ system voltage and interrupt/breaking rating ≥ available fault current (NASA: 125 V fuses can sustain arcs above 50 V).
- [ ] **3.10.4** I²t and pulse-cycle withstand adequate for repetitive inrush.

### 3.11 Crystals / oscillators
- [ ] **3.11.1** External load caps computed so total CL matches spec: **CL = (C1·C2)/(C1+C2) + Cstray**, Cstray typically **2–5 pF**. Do not set external caps equal to CL. *(Major — ~−15 to −30 ppm/pF error.)*
- [ ] **3.11.2** Negative-resistance (startup) margin: |Rneg| ≥ **5×** crystal ESR (vendors state 4–10×) across V/T/process. *(Major.)*
- [ ] **3.11.3** Drive level below max (DL = ESR × I_RMS²); series damping resistor added if needed (32.768 kHz forks target <1 µW). NASA derates crystal current 0.5 or power 0.25.
- [ ] **3.11.4** Frequency tolerance/stability (initial+temp+aging) meets the protocol: USB ±500 ppm, CAN ≤±0.5%, Ethernet ±50 ppm, timekeeping <±20 ppm. *(Major.)*
- [ ] **3.11.5** Crystal only where the IC has an integrated oscillator; otherwise use an oscillator module. MEMS: verify jitter acceptable.
- [ ] **3.11.6** Feedback resistor value appropriate (5–15 MΩ for 32.768 kHz; 470 kΩ–10 MΩ for MHz) if not integrated.

### 3.12 Connectors, relays, optocouplers, LEDs
- [ ] **3.12.1** Connector current per pin within rating at temperature (NASA: per equivalent wire-gauge derating; Tmax − 25 °C).
- [ ] **3.12.2** Connector voltage derated (NASA: 25% of dielectric-withstand or 75% of rated working V, whichever lower); creepage/clearance adequate.
- [ ] **3.12.3** Mating cycles ≥ field usage; keying prevents reverse insertion; latching adequate for shock/vibration.
- [ ] **3.12.4** Relay contacts derated for load type (NASA: resistive 0.75; inductive/lamp lower); coil voltage/current NOT derated.
- [ ] **3.12.5** Optocoupler CTR margin designed for end-of-life CTR (often 50% of initial); isolation rating meets safety requirement.
- [ ] **3.12.6** LED current-limit resistor computed at worst-case Vf tolerance and supply; LED current within rating at temperature.

### Per-Passive Derating Template
| RefDes | Type/Dielectric | MPN | Rated (V/W/A/°C) | Applied worst-case | Derating std & factor | Derated limit | Margin | Pass/Fail | Evidence (§/pg) |
|---|---|---|---|---|---|---|---|---|---|

---

## Section 4 — Per-Pin IC Review Methodology

> For **every critical IC** (MCU/MPU, FPGA, SoC, PMIC/regulator, memory, transceiver, ADC/DAC, sensor, motor driver), complete the **Per-IC Pin Table**, walking **every pin** against the datasheet. Never assume unused-pin handling — always read the explicit datasheet instruction.

### 4.1 Supplies & decoupling
- [ ] **4.1.1** Every VDD/VCC/VDDA/VBAT/VREF pin fed by the correct rail and within recommended operating range (not just abs-max).
- [ ] **4.1.2** Decoupling on every supply pin, meeting/exceeding the datasheet values and count (rule of thumb: one local cap per power pin/ball pair; for BGAs ~1 cap per 2–4 power balls). *(Major.)*
- [ ] **4.1.3** Bulk + local tiering present (bulk 10–100 µF near regulator; mid 1–10 µF; local 100 nF; add 10 nF per datasheet). Smallest cap closest to the pin.
- [ ] **4.1.4** Analog supplies filtered/isolated from digital (bead or RC), with the resonance check of 3.6.8.

### 4.2 Absolute-maximum & logic levels
- [ ] **4.2.1** Applied voltage on every pin ≤ abs-max under all conditions (transients, back-drive, sequencing skew). *(Critical.)*
- [ ] **4.2.2** Driver VOH/VOL vs receiver VIH/VIL verified for every interface (1.8 V driver into 3.3 V CMOS often fails VIH). Level shifters where domains differ. *(Critical.)*
- [ ] **4.2.3** 5 V-tolerant vs non-tolerant confirmed explicitly from the datasheet (do not assume). *(Critical.)*
- [ ] **4.2.4** Auto-sensing level shifters: far side has no conflicting pull that defeats direction sensing.
- [ ] **4.2.5** Output drive strength adequate for load; open-drain outputs have pull-ups; PECL/LVDS have correct terminations/pull-downs.

### 4.3 Reset, enable, boot/strap, config
- [ ] **4.3.1** Every pin needing a defined boot state has a pull of the correct value tied to the correct rail. *(Critical.)*
- [ ] **4.3.2** Strap/config pins do not conflict with functional (post-boot) use; shared straps not corrupted at reset.
- [ ] **4.3.3** Reset timing (RC/supervisor) meets minimum reset-low and power-good windows; brown-out vs rail droop checked (Section 10).
- [ ] **4.3.4** Enable/inhibit polarity correct (active-high vs -low) for every device.
- [ ] **4.3.5** Reference/program resistors (bias, ISET) correct value and correct rail.

### 4.4 Analog, reference, compensation
- [ ] **4.4.1** ADC source impedance meets the datasheet max for the sampling rate (RC settling vs sample time); anti-alias filter present.
- [ ] **4.4.2** Reference pins decoupled and driven within spec; reference noise/accuracy adequate for the resolution.
- [ ] **4.4.3** Compensation / loop-filter / bootstrap / soft-start networks present with datasheet values.
- [ ] **4.4.4** Op-amp feedback polarity correct; RC attenuator time constant sane vs ADC sampling.

### 4.5 Ground/thermal, oscillator, debug, bus
- [ ] **4.5.1** Exposed/thermal pad connected to the correct net (often GND, sometimes a power rail or specific node — verify!) with adequate thermal-via array. *(Critical — wrong-net EPAD shorts the part.)*
- [ ] **4.5.2** Analog vs digital ground pins connected per the datasheet grounding scheme.
- [ ] **4.5.3** Oscillator pins meet load-cap and layout rules of 3.11; guard ring/ground under the crystal.
- [ ] **4.5.4** JTAG/SWD/debug and programming/boot access provided for every programmable device; debug NOT power-gated in sleep. *(Major.)*
- [ ] **4.5.5** Config/boot flash provided for every FPGA/MPU without internal flash.
- [ ] **4.5.6** I²C: no duplicate device addresses on a bus; address straps correct; pull-ups sized per 4.6.
- [ ] **4.5.7** Differential-pair polarity and pin swapping verified (TX/RX not crossed; P/N not swapped unless the standard/IC allows inversion). *(Major.)*
- [ ] **4.5.8** FPGA I/O-bank voltage rules met; clock-capable input pins used for clocks (Xilinx single-ended clocks on _P).
- [ ] **4.5.9** Back-powering/leakage: no rail powered through an IC's ESD/protection diodes from an I/O high while the rail is off; latch-up path when unpowered analyzed. *(Critical.)*
- [ ] **4.5.10** Pinout verified against the actual package/footprint variant ordered (pin-1, ballmap, suffix).

### 4.6 I²C / bus pull-up sizing (per NXP UM10204, Rev. 7.0, 1 Oct 2021)
- [ ] **4.6.1** Pull-up **Rp(min)** = (VDD − VOL(max))/IOL, with specified minimum sink current **IOL = 3 mA** (Standard/Fast) or 20 mA (Fast-mode Plus): e.g., (3.3 − 0.4)/3 mA ≈ 967 Ω, use ≥ ~1 kΩ. *(Major.)*
- [ ] **4.6.2** Pull-up **Rp(max) = tr/(0.8473 × Cb)**: tr = 300 ns (Fast Mode), Cb = 100 pF → Rp(max) ≈ 3.5 kΩ. Total bus capacitance ≤ 400 pF (Std/Fast).
- [ ] **4.6.3** Chosen value near the geometric mean (~1.5 kΩ typical for Fast Mode at 100 pF); rise-time limits met (1000 ns Std / 300 ns Fast / 120 ns FM+ / 40 ns HS).

### Per-IC Pin Table Template
| Pin # | Pin name | Function used | Net | Rail/domain | Abs-max | Applied worst-case | Required pull/term/decap | Present? | Unused-pin instruction (§) | Pass/Fail | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|

---

## Section 5 — Power Supply Design Review

### 5.1 Input protection
- [ ] **5.1.1** Reverse-polarity protection present (series P-FET / Schottky / bridge), rated for max current. *(Critical.)*
- [ ] **5.1.2** Fuse and/or over-voltage protection (TVS/crowbar) at the inlet. *(Major.)*
- [ ] **5.1.3** Inrush/soft-start: total input capacitance computed; NTC/soft-start/e-fuse added if excessive; hot-plug SOA of any pass device checked (3.9.5).
- [ ] **5.1.4** TVS at inlet clamps below downstream abs-max (per 3.8).

### 5.2 Linear regulators / LDO
- [ ] **5.2.1** Dropout voltage satisfied at min VIN and max load over temperature.
- [ ] **5.2.2** LDO power dissipation = (VIN − VOUT)×IOUT within package/thermal limit; Tj checked (Section 7). *(Major.)*
- [ ] **5.2.3** Output-cap type/ESR within the LDO stability window (verify against the datasheet stability plot). *(Major.)*
- [ ] **5.2.4** Feedback divider gives correct VOUT with acceptable tolerance; minimum-load requirement met.
- [ ] **5.2.5** Quiescent current acceptable for battery/standby budget.

### 5.3 Switching converters (buck/boost/buck-boost)
- [ ] **5.3.1** Inductor ripple ratio ΔIL ≈ 20–40% of IOUT; L ≈ (VOUT·(1−D))/(ΔIL·fsw); saturation check per 3.6.1.
- [ ] **5.3.2** Output-cap ripple within spec; input-cap RMS current rating ≥ the converter's input ripple current. *(Major.)*
- [ ] **5.3.3** Loop compensation gives crossover ~fsw/10–fsw/5 with ≥45–60° phase margin; Type-II/III matched to output-cap ESR zero.
- [ ] **5.3.4** Boost/buck-boost: right-half-plane zero accounted for (crossover well below fRHPZ); min on/off-time and max duty-cycle limits not violated across VIN. *(Major.)*
- [ ] **5.3.5** Switching frequency chosen with EMI bands in mind (keep harmonics out of AM/FM/CISPR-25 bands; spread-spectrum where useful).
- [ ] **5.3.6** Bootstrap cap and (if used) snubber (RC after SW-node scope check, e.g., ~2.2 Ω//1 nF) present.
- [ ] **5.3.7** Feedback trace Kelvin-senses at the true output/load node and routes away from the SW node and inductor. *(Major.)*
- [ ] **5.3.8** **Hot-loop minimized**: the high-di/dt loop (input cap → high-side switch → low-side switch/diode → back to cap) is physically smallest, with the smallest/flattest ceramic closest. Per ADI AN-139 (an139fa), "Only in the green loop flows a fully switched AC current, switched from zero to IPEAK and back to zero. We refer to the green loop as a hot loop, since it has the highest AC and EMI energy." *(Major.)*

### 5.4 Sequencing, transient, budget
- [ ] **5.4.1** Power-sequencing order and inter-rail timing meet every device's datasheet; sequencer/enable-chaining/RC delays verified against required slew. *(Critical for FPGA/SoC/DDR.)*
- [ ] **5.4.2** Load-transient droop within the load's tolerance; output caps sized for the load step.
- [ ] **5.4.3** Efficiency and total loss computed; converter/LDO thermal within budget at max ambient.
- [ ] **5.4.4** Current-sense resistors placed after the output caps, not inside the switching loop.
- [ ] **5.4.5** Remote sense used on low-voltage/high-current rails where IR drop matters.
- [ ] **5.4.6** **Power-budget spreadsheet** exists: every rail's worst-case load summed with margin against regulator rating, source capacity, and connector/trace current. *(Major.)*

### 5.5 Battery / charging
- [ ] **5.5.1** Charge current, termination, pre-charge set correctly; charger input OVP present.
- [ ] **5.5.2** Battery thermistor (NTC) present/configured; charging inhibited outside the temperature window.
- [ ] **5.5.3** Cell protection (OVP/UVP/OCP), fuel-gauge sense, pack polarity/keying verified; reverse-battery and short-circuit behavior safe.

---

## Section 6 — Grounding, Decoupling & Signal Integrity

- [ ] **6.1** Decoupling placement: caps within a few mm of the pin with minimal loop inductance; effective bandwidth is set by **mounting inductance**, not capacitance value. Placing decaps at the board edge "defeats the purpose." *(Major.)*
- [ ] **6.2** Target-impedance method for high-current cores: **Ztarget = ΔV/ΔI** (ΔV ≈ 5% of rail); PDN keeps impedance below Ztarget across frequency; anti-resonance peaks between cap tiers checked (value ratios not too close, or ESR-damped).
- [ ] **6.3** Plane stitching: adjacent power/ground planes stitched with vias/caps; ground stitching vias around the board and near connectors.
- [ ] **6.4** Return-path continuity: no high-speed signal crosses a split/gap in its reference plane; stitching caps/vias where a signal changes reference layers. *(Major — CM radiation, SI failure.)*
- [ ] **6.5** Layer stackup defined with the fab; controlled-impedance layers identified; symmetric stackup to avoid warp; signal layers not adjacent without a reference plane.
- [ ] **6.6** Controlled-impedance targets set per interface: **USB 2.0 90 Ω ±15% diff (45 Ω SE)**; USB3/USB-C 90 Ω; **Ethernet 100 Ω diff**; HDMI/DP 100 Ω; **PCIe 85 Ω** (lower than the rest); MIPI/LVDS/SATA 100 Ω; DDR per JEDEC. *(Major.)*
- [ ] **6.7** Length-matching & skew budgets: USB 2.0 HS intra-pair skew ≤ ~100 ps; USB3 length-match ~10 mil; DDR byte-lane/address-command per the SoC guide; PCIe/SerDes per spec; MIPI data-to-clock skew controlled. *(Major.)*
- [ ] **6.8** Differential-pair spacing/coupling consistent; symmetry maintained (asymmetry converts differential energy to common-mode radiation).
- [ ] **6.9** Crosstalk controlled with the 3W rule (edge-to-edge ≥ 3× trace width); ≥3× width separation of high-speed from clocks/power.
- [ ] **6.10** Stubs minimized; via stubs on high-speed nets addressed (back-drill or layer choice) where the data rate warrants.
- [ ] **6.11** Terminations correct: series (source) for point-to-point CMOS, parallel/Thevenin/AC for buses, AC-coupling caps on gigabit SerDes. *(Major.)*
- [ ] **6.12** Clock routing: length/impedance controlled, guarded, away from I/O and board edges; jitter budget met.
- [ ] **6.13** Analog/digital/RF/switching regions physically partitioned; sensitive analog away from switchers and clocks.
- [ ] **6.14** Mixed-signal grounding scheme deliberate (single reference plane preferred over split planes per Hartley/Bogatin guidance); any moat/split has a defined, non-crossed return.
- [ ] **6.15** Chassis/earth ground and isolation barriers defined; creepage/clearance across isolation respected (Section 8).
- [ ] **6.16** RS-485/CAN: A/B pair routed as a matched ~100–120 Ω differential pair; termination (120 Ω) only at the two physical bus ends; fail-safe bias resistors (e.g., pull-up on A, pull-down on B) present; stubs kept < ~0.3–0.5 m. *(Major.)*

---

## Section 7 — EMC / EMI / ESD / Thermal Design

- [ ] **7.1** Common-mode chokes on cable interfaces (USB, Ethernet, CAN, power) where CM emissions/immunity require.
- [ ] **7.2** Cable/connector interfaces filtered (pi/RC/bead) and protected (TVS/ESD at entry per 3.8).
- [ ] **7.3** Shield/chassis grounding: mounting holes grounded where intended; shield-can grounding adequate; connector shells bonded.
- [ ] **7.4** Aperture/slot control: no long slots in reference planes near high-speed nets (slot antennas).
- [ ] **7.5** ESD path routed to chassis/ground away from sensitive nodes; ground stitching supports the path.
- [ ] **7.6** Radiated-emission risk points reviewed: SMPS hot loops, high-dV/dt SW nodes minimized/shielded, no unterminated/overshooting clocks.
- [ ] **7.7** Immunity design: EFT/surge/RF paths considered; RFI rectification on high-impedance analog inputs mitigated (input RC/filtering).
- [ ] **7.8** **Junction-temperature calculation** for every high-power device: Tj = Ta + P×θJA — but θJA is board/environment-dependent, not a constant; datasheet θJA is only a first-order estimate. Prefer θJC + board thermal model, and use the **enclosure internal ambient** (warmer than external) for Ta. Confirm Tj ≤ derated limit (NASA: ≤110 °C microcircuits / ≤125 °C discretes, or 40 °C below rated). *(Major.)*
- [ ] **7.9** Copper area/pour and thermal-via arrays sized for power devices (exposed-pad parts: filled/capped vias under the pad, large copper heat-spreader, avoid thermal-relief on the thermal pad).
- [ ] **7.10** Airflow/derating at max ambient considered; heatsinks specified where needed; hot parts kept away from temperature-sensitive parts (electrolytics, crystals, references, sensors).

---

## Section 8 — Layout / PCB Physical Review

- [ ] **8.1** Every footprint verified against the manufacturer land pattern / IPC-7351 (pad size, pitch, courtyard). *(Critical — wrong footprint = unbuildable.)*
- [ ] **8.2** Pin-1 markers and polarity indicators present and correct on silkscreen and assembly layers.
- [ ] **8.3** Courtyard/keep-out and mechanical clearances respected; no body/height collisions with the enclosure.
- [ ] **8.4** Silkscreen legible, not over pads/vias; minimum text height ~25 mil, line width ~4 mil (typical fab).
- [ ] **8.5** Solder-mask expansion correct; SMD vs NSMD pads chosen deliberately (NSMD typical for BGA).
- [ ] **8.6** Via strategy: tented vs via-in-pad decided; via-in-pad filled and capped/plated-over (esp. under BGA/thermal pads) to prevent solder wicking. *(Major.)*
- [ ] **8.7** Minimum trace/space ≥ fab capability at the chosen copper weight; outer-layer traces not below ~4 mil.
- [ ] **8.8** Drill sizes and aspect ratio within fab capability; annular ring meets IPC-6012 class (Class 2 allows 90° breakout; **Class 3 requires zero breakout**, internal annular ring ≥ ~1 mil, external ≥ ~2 mil). *(Major.)*
- [ ] **8.9** Copper-to-edge clearance meets fab minimum (typically ≥ ~8–10 mil, more for routed edges).
- [ ] **8.10** **Creepage/clearance** for voltage: per IPC-2221, general minimum spacing 0.1 mm (<15 V internal); tables scale with voltage; above 500 V uncoated external = 2.5 + 0.005×(V−500) mm. IPC-2221 "low voltage" is <15 V. For mains/safety use IEC 62368-1/60664-1 creepage (pollution degree + CTI), which override IPC. Apply altitude correction (1.7). *(Critical for HV/mains.)*
- [ ] **8.11** **Trace width for current** sized per IPC-2152 (test-based), not legacy IPC-2221 charts. Sanity check (IPC-2221 external, 1 oz, 10 °C rise): ~10 mil ≈ 1.0 A, 20 mil ≈ 1.7 A, 50 mil ≈ 3.5 A; internal ≈ 50–70% of external. *(Major.)*
- [ ] **8.12** Plane thermal-relief vs solid connection chosen appropriately (relief for hand-solder TH; solid for high-current/thermal).
- [ ] **8.13** Copper balance across layers to avoid warpage; large copper areas hatched where needed.
- [ ] **8.14** Panelization/V-score/tab-route + mouse-bites planned; ceramics and stress-sensitive parts away from break edges/depanel stress (3.2.6).
- [ ] **8.15** Fiducials present (global + local for fine-pitch/BGA).
- [ ] **8.16** Board outline, mounting holes, connector positions match the mechanical drawing; connector mating access/orientation verified.
- [ ] **8.17** Component-height restrictions respected per zone.
- [ ] **8.18** Test-point access for ICT/flying-probe: adequate size, preferred side (bottom for bed-of-nails), clear of edges/hardware.
- [ ] **8.19** DFM/DFT/DFA review passed with the fab/assembler capability sheet.
- [ ] **8.20** Assembly orientation and tombstoning risk reviewed (symmetric pads/thermal balance on small 2-terminal parts).
- [ ] **8.21** Moisture-sensitivity level (MSL) of parts noted; bake/handling plan for high-MSL parts.
- [ ] **8.22** RoHS/lead-free process temperature compatible with all parts (peak reflow vs rating); paste/stencil layer for thermal pads (windowpane to control paste volume).

---

## Section 9 — BOM Analysis

- [ ] **9.1** BOM complete and matches the schematic 1:1 (every placed part present; no orphan lines; DNP flagged). *(Critical.)*
- [ ] **9.2** Every line has a fully-specified MPN — tolerance, voltage, dielectric, package, temperature grade (no generic "0.1 µF cap"). *(Major.)*
- [ ] **9.3** Footprint in layout matches the MPN's actual package (0402 vs 0603, SOT-23 variants). *(Critical.)*
- [ ] **9.4** Lifecycle status checked for every active/critical part: Active/Mature/NRND/LTB/EOL/Obsolete. NRND flagged and justified; no obsolete parts. (Distributor flags lag the manufacturer — check the vendor product page for high-risk parts.) *(Major.)*
- [ ] **9.5** Stock availability and lead time checked against the build schedule; long-lead parts (>26–52 weeks) flagged.
- [ ] **9.6** Multi-sourcing: critical parts have ≥2 approved sources or a qualified Form-Fit-Function alternate; single-source parts flagged with a mitigation. *(Major.)*
- [ ] **9.7** Pricing rolled up at target volume; MOQ and packaging (reel/cut-tape/tray) noted for assembly.
- [ ] **9.8** Counterfeit risk minimized: authorized/franchised distributors; obsolete/gray-market buys require AS6081/IDEA-STD-1010 inspection and traceability.
- [ ] **9.9** Temperature grade of every part ≥ product spec; AEC-Q100/Q200 or medical/space qualification present where required. *(Major.)*
- [ ] **9.10** RoHS/REACH and (if required) conflict-minerals compliance verified per part.
- [ ] **9.11** MSL recorded per part; package compatible with the assembler's capability (min pitch, BGA, QFN).
- [ ] **9.12** Line-count consolidation of similar values to reduce reels/cost without compromising function.
- [ ] **9.13** No part-number typos; internal PN ↔ MPN mapping correct; BOM under version control tied to the schematic revision.

---

## Section 10 — Firmware / Hardware Interface Checks

- [ ] **10.1** Bootloader/programming interface accessible (SWD/JTAG/ISP/USB-DFU) and not power-gated. *(Major.)*
- [ ] **10.2** Strap-pin states valid at the reset instant (timing vs supply ramp), not just at steady state. *(Critical.)*
- [ ] **10.3** Watchdog present/enabled with a safe timeout; independent of the main clock where safety requires.
- [ ] **10.4** Brown-out/BOD threshold above the point where logic misbehaves and matched to worst-case rail droop under transients. *(Major.)*
- [ ] **10.5** GPIO default/power-up states (typically high-Z with weak pulls) are safe for the external circuit — MOSFET gates, motor-enable, gate-driver, and load-switch pins default to the **off/safe** state via external pulls, not relying on firmware. *(Critical — unintended motor/heater/actuator turn-on at boot.)*
- [ ] **10.6** Defined safe-state behavior on fault/reset/brown-out for all actuators and outputs.
- [ ] **10.7** Board revision readable by firmware (GPIO/resistor-strap/ADC divider) for traceability.

---

## Section 11 — Manufacturing Outputs & Documentation

- [ ] **11.1** Fabrication data complete and self-consistent: Gerber (RS-274X) or ODB++ or IPC-2581, with all copper, mask, silk, paste, drill layers.
- [ ] **11.2** Drill files (plated/non-plated separated), drill chart, and legend present.
- [ ] **11.3** Netlist exported (IPC-D-356) for the fab to net-test bare boards against.
- [ ] **11.4** Assembly drawings + notes present; pick-and-place (centroid) file with correct origin, side, and **rotation** convention. *(Major — wrong rotation = mass mis-assembly.)*
- [ ] **11.5** Stackup document provided to the fab with impedance targets and tolerances.
- [ ] **11.6** Fab notes specify: surface finish (ENIG/HASL/OSP/immersion silver), controlled-impedance requirement, material Tg/Td/CTI, board thickness, copper weight per layer, min trace/space, finished-hole tolerances.
- [ ] **11.7** IPC class stated on the fab drawing (Class 2 vs Class 3) with any AABUS. Confirm the fab can meet the Class 3 vs Class 2 deltas: PTH copper wall **25 µm avg (Class 3)** vs **20 µm (Class 2)**; **zero annular-ring breakout (Class 3)** vs 90° allowed (Class 2); PTH barrel fill ≥75% (Class 3, no exception) vs a conditional 50% for Class 2; circumferential wetting 270° (Class 3) vs 180° (Class 2); no copper voids (Class 3) vs one void in ≤5% of holes (Class 2). *(Major.)*
- [ ] **11.8** Acceptance criteria / workmanship standard cited (IPC-A-610H class; IPC-6012F fab; J-STD-001 solder).
- [ ] **11.9** **Final loop-closure check:** re-import the exported Gerbers/ODB++ into a viewer and compare against the source layout and netlist (catches export mistakes, missing layers, wrong apertures). *(Critical.)*

---

## Section 12 — Verification, Test & Bring-up Planning

- [ ] **12.1** Written power-up/bring-up procedure exists (current-limited supply, staged rail enable, expected current at each step).
- [ ] **12.2** Inrush and quiescent current expectations documented; a protective current limit set for first power-on.
- [ ] **12.3** Test-point coverage adequate for ICT/flying-probe/boundary-scan; ground clips near analog test points; ground on all rails.
- [ ] **12.4** Boundary-scan (JTAG) chain verified for BGAs/inaccessible nets; bed-of-nails/ICT fixture feasibility confirmed.
- [ ] **12.5** First-article inspection plan (AOI, X-ray for BGA, cross-section for Class 3) defined.
- [ ] **12.6** Design-review sign-off records captured (reviewer, date, action items, disposition). Schematic and layout frozen at the reviewed revision.
- [ ] **12.7** Bring-up checklist covers: clocks running (scope XIN), reset released, rails in tolerance/sequence, programming successful, each interface link-up, thermal check under load.

---

## Section 13 — Common Failure Modes & "Gotchas"

- [ ] **13.1** MLCC nameplate vs effective capacitance: a 22 µF/25 V 0603 at 16.8 V can deliver only ~3 µF — under-decoupling and regulator instability. *(Major.)*
- [ ] **13.2** Ferrite-bead + cap peaking: a bead feeding a sensitive rail can turn a filter into a resonant amplifier (gain instead of attenuation) around 0.1–10 MHz — add damping. *(Major.)*
- [ ] **13.3** Tantalum ignition: undersized/under-derated MnO₂ tantalum on a low-impedance source can catch fire — 50% derate + inrush limiting. *(Critical.)*
- [ ] **13.4** Wrong-net exposed pad, or EPAD not connected/vias missing — dead or overheating part. *(Critical.)*
- [ ] **13.5** Crystal load caps set equal to CL (frequency off) or insufficient negative-resistance margin (intermittent no-start). *(Major.)*
- [ ] **13.6** Level-shift omission: 1.8 V ↔ 3.3 V ↔ 5 V mismatches; open-drain nets missing pull-ups. *(Critical.)*
- [ ] **13.7** GPIO boot state driving a MOSFET/motor/heater on at power-up before firmware runs. *(Critical.)*
- [ ] **13.8** High-speed net crossing a plane split — SI/EMC failure that passes DRC. *(Major.)*
- [ ] **13.9** SMPS hot loop routed large / feedback picked up near the SW node — noise, poor regulation, EMC fail. *(Major.)*
- [ ] **13.10** Flipped flat-flex / mirrored cable pinout between boards; connector keying absent. *(Major.)*
- [ ] **13.11** Melting LED/plastic parts from reflow or Vf-tolerance current spikes; parts exceeding peak reflow temperature. *(Minor–Major.)*
- [ ] **13.12** ERC/DRC "clean" mistaken for "correct" — derating, abs-max, sequencing, SI are not checked by these tools. *(Major.)*
- [ ] **13.13** Cracked MLCC near a depanel/mounting-hole stress point → latent short. *(Major.)*
- [ ] **13.14** Back-powering an unpowered rail through an IC's I/O ESD diodes; latch-up on hot-plug. *(Critical.)*
- [ ] **13.15** Reused symbol/footprint from a library with a wrong pin map or wrong package variant. *(Critical.)*

---
