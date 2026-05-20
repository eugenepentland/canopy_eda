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
| `(net "A" "B" …)` | DSs | Tie one or more nets to a canonical name (net-merge). |
| `(bus-net "PREFIX" width "OTHER" …)` | DSs | Tie corresponding lanes of two multi-bit buses together. |
| `(pins "REF" (group "label") pin-form…)` | ·Ss | Group a main-IC's pin assignments under a sub-section. |
| `(protocol atom)` | ·Ss | Tag a section with a protocol keyword (e.g. `usb`, `i2c`). |
| `(calc …)` | ·Ss | Inline design math block, surfaced in the review report. |
| `(description "text")` | ·Ss | One-line section description used in the review report and overview SVG. |
| `(status concept|implemented|review)` | ·Ss | Section completion status. Inferred when omitted. |
| `(role input|output)` | ·S· | Tag a section as a block input or output for the overview diagram. |
| `(diagram hidden)` | ·S· | Opt this section out of the block-diagram view (schematic card still renders). |
| `(group …)` | D·· | Visual group annotation rendered in the schematic. |
| `(sub-block "name" (module-call args…))` | D·· | Instantiate a parameterised module inside the design. |
| `(verifies (req "REF" REQID) [rationale])` | D·· | Mark a requirement as satisfied by a specific instance. |
| `(test-point …)` | D·· | Declare a measurement / bring-up access point. |
| `(power-config (derating N))` | D·· | Per-design power-budget configuration knobs. |
| `(kicad-pcb "absolute/path/to/board.kicad_pcb")` | D·· | Declare the PCB file the file-based KiCad sync writes board updates to. |
