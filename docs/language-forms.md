# S-Expression Language: Form Reference

<!-- Auto-generated from src/eval/forms.zig. Do not edit by hand —
     run `zig build run -- gen-language-docs` to regenerate. -->

Every special form, builtin operator, and design-scope form the
evaluator recognises, with its arity contract and a one-line
summary. The hand-written prose lives in
[`sexp-language.md`](sexp-language.md); this file is the
machine-checked grammar surface.

## Special forms

Arguments are passed un-evaluated; each form decides what to evaluate.

| Form | Arity | Summary |
| --- | --- | --- |
| `(let name expr)` | 2 | Bind `name` to the evaluated value of `expr` in the current scope. |
| `(if cond then else)` | 3 | Short-circuit conditional. Only the matching branch is evaluated. |
| `(cond (test1 expr1) … (else exprN))` | 1+ | Walk clauses in order, returning the first matching expression's value. |
| `(import name)` | 1 | Load a library component or module by name. Searches `lib/components/` then `lib/modules/`. |
| `(defmodule name (params…) body…)` | 3+ | Define a parameterised module that closes over the surrounding env. |
| `(design-block "name" form…)` | 1+ | The root container — every `.sexp` design file evaluates to one. |
| `(assert cond "message")` | 2 | Record a pass/fail entry. Failures surface in the review report, never aborts the build. |
| `(assert-range value lo hi "label")` | 4 | Record an assertion that `value` is in `[lo, hi]`, with a formatted diagnostic. |
| `(fmt "template" args…)` | 1+ | Format a string using `~V`/`~R`/`~C`/`~A`/`~S` directives. |
| `(id <hex8>)` | — | Stable 8-char identifier auto-inserted by the build. Evaluator short-circuits to `.nil`. |

## Builtin operators

Arithmetic, comparison, and logic operators. Arguments are evaluated left-to-right before the operator runs.

| Form | Summary |
| --- | --- |
| `(+ a b)` | Numeric addition. |
| `(- a b)` | Numeric subtraction. |
| `(* a b)` | Numeric multiplication. |
| `(/ a b)` | Numeric division. Errors on divide-by-zero. |
| `(% a b)` | Numeric modulo. Errors on divide-by-zero. |
| `(> a b)` | Numeric greater-than → boolean. |
| `(>= a b)` | Numeric greater-or-equal → boolean. |
| `(< a b)` | Numeric less-than → boolean. |
| `(<= a b)` | Numeric less-or-equal → boolean. |
| `(== a b)` | Equality, defined for number-number and string-string. |
| `(!= a b)` | Inequality, defined for number-number and string-string. |
| `(and a b)` | Boolean and (eager — both args evaluated). |
| `(or a b)` | Boolean or (eager — both args evaluated). |
| `(not a)` | Boolean negation. |

## Design-scope forms

Forms that may appear directly inside a `(design-block …)`, a
`(section …)`, or a nested sub-section. The scope column lists
where each is accepted: **D** = design-block top level,
**S** = section, **s** = sub-section.

| Form | Scope | Summary |
| --- | --- | --- |
| `(instance "REF" component pin…)` | DSs | Place a component with inline pin-to-net bindings. |
| `(port "name" [net] dir [(rated lo hi)])` | DSs | Declare a block boundary signal. |
| `(bus-port "prefix" width dir …)` | DSs | Declare a multi-bit boundary bus that expands to one port per lane. |
| `(note "id" "text" [(ref …)])` | DSs | Attach a design-time note to the surrounding scope. |
| `(section "name" ["subtitle"] form…)` | DSs | Functional subsystem card. Inside `(section …)` nests one level into a sub-section. |
| `(decouple "NET" item…) | (decouple (cap-0402 "100nF") N per-pin "REF" "NET1" …)` | DSs | Emit decoupling capacitors against a net, in single- or multi-net form. |
| `(series …)` | DSs | Insert a series element (resistor / ferrite / etc.) between two nets. |
| `(fanout "COMMON" (comp) "NET1" "NET2" … [(id …)])` | DSs | Place one component from a shared COMMON net to each listed net (star of series elements). |
| `(net "A" "B" …)` | DSs | Tie one or more nets to a canonical name (net-merge). |
| `(bus-net "PREFIX" lo hi "SUB") | (bus-net "PREFIX" lo hi (suffixes …) (over …) (ports …))` | DSs | Tie a lane range to a sub-block bus (1:1), or strided-fan-out the range across several sub-blocks' ports. |
| `(pins "REF" (group "label") pin-form…)` | ·Ss | Group a main-IC's pin assignments under a sub-section. |
| `(protocol atom)` | ·Ss | Tag a section with a protocol keyword (e.g. `usb`, `i2c`). |
| `(calc …)` | ·Ss | Inline design math block, surfaced in the review report. |
| `(description "text")` | ·Ss | One-line section description used in the review report and overview SVG. |
| `(status concept|implemented|review)` | ·Ss | Section completion status. Inferred when omitted. |
| `(role input|output)` | ·S· | Tag a section as a block input or output for the overview diagram. |
| `(diagram hidden)` | ·S· | Opt this section out of the block-diagram view (schematic card still renders). |
| `(hosts "sub1" "sub2" …)` | ·S· | Fold the named sub-blocks into this section's block-diagram node (explicit attachment). |
| `(category <key>)` | ·S· | Set this section's diagram category (e.g. mcu, power, rf), overriding the name heuristic. |
| `(group …)` | D·· | Visual group annotation rendered in the schematic. |
| `(sub-block "name" (module-call args…))` | D·· | Instantiate a parameterised module inside the design. |
| `(verifies (req "REF" REQID) [rationale])` | D·· | Mark a requirement as satisfied by a specific instance. |
| `(design-doc (critical-ic comp (role "…") (rationale "…") (mpn "…")) …)` | D·· | Up-front critical-IC lifecycle / traceability declaration for the design. |
| `(test-point …)` | D·· | Declare a measurement / bring-up access point. |
| `(power-config (derating N))` | D·· | Per-design power-budget configuration knobs. |
| `(decouple-defaults (ic "REF") (bypass (comp)))` | D·· | Set per-design decouple defaults: a fallback IC ref and bypass cap so (decouple …) can omit both. |
| `(kicad-pcb "absolute/path/to/board.kicad_pcb")` | D·· | Declare the PCB file the file-based KiCad sync writes board updates to. |
| `(function "Name" ["subtitle"] [(verb "…")] [(stack N)] [(chain pos "stage")] (includes "section"…))` | D·· | Declare a high-level functional subsystem for the Function view; (chain …) also places it on the Signal Chain view's narrative spine. |
| `(stub "name" [(role …)] [(mpn …)] [(category key)] [(size W H)] [(channels N)] [(ref "REF")] (signal "name" class "net")…)` | D·· | Declare a placeholder part — auto-placed, sized bounding box, signal-wired, optionally N stacked channels — for design-phase diagrams before a real component exists. |
| `(layout (anchor "name") (place "name" (right-of|left-of|above|below "ref"))…)` | D·· | Declare a Mermaid-style free-floating block-diagram layout by positioning blocks relative to one another. |
| `(placement-order "HUB" "REF"… | (near <pin> "REF")…)` | D·· | Order the passives around a hub for PCB auto-placement (first = highest priority); (near …) also pins which hub pad a cap's loop targets. |
| `(constraints | module "name" (power-rail L (role input) (net N)) (proximity REF (to-pin HUB PIN) (max n mm) (priority …)) (net-length (net N) (minimize) (priority …)) (deprioritize (REF…)) (keep-out (net N)|(part REF) (from REF) (min n mm)) (group (REF…) (style …)) …)` | D·· | Phase-A PCB placement constraints (circuit intent the auto-placer can't infer): rail roles, proximity pulls, weighted nets, deprioritized straps, keep-outs, groups. Refs/nets/pins validated against the netlist. See docs/constraints_dsl.md. |
| `(placement (anchor "REF") (left|right|top|bottom "REF"… | (rot N "REF") | (net "NAME")…)… [(switch "REF" side)] [(no-refine)] [(centered)])` | D·· | Agent-authored PCB floorplan: declare each part's side of the main IC, the order along that edge, and an optional rotation; the solver legalizes it to exact coordinates (the manual twin of the automatic switcher floorplan). A (net "VIN") item is a membership rule: every not-otherwise-claimed part with a pad on that net joins the side (smallest first) — survives part additions. Parts no side lists are pin-hug auto-filled beside their placed pads. (no-refine) shows the raw constructive pack (flush, symmetric); (centered) centers every side on the IC instead of opposite its rail pad. |
