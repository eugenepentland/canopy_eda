---
name: Bug report
about: Something is wrong — a design evaluates, renders, checks or exports incorrectly, or a command fails
title: ''
labels: bug
assignees: ''
---

<!--
Please do NOT report a security vulnerability here. Use the Security tab →
"Report a vulnerability". See SECURITY.md.
-->

## What happened

<!-- One or two sentences. What did you expect, and what did you get instead? -->

## Version and environment

- `netlisp version` output:
- OS and architecture:
- Built from source? If so, `zig version`:

## Minimal reproduction

<!--
Cut this down as far as you can. A bug that needs your whole board is a bug
nobody can bisect. If it needs a library file (a component, footprint, pinout
or module), paste that too.
-->

```lisp
; src/repro.sexp

```

## Command

<!-- The exact command, including --project-dir and any flags. -->

```bash

```

## Output

<!--
Verbatim and complete, not summarized. Error text, source spans and
line/column numbers are how the parser and evaluator report where they were.
-->

```

```

## Anything else

<!--
Screenshots for a rendering or layout bug, the exported file for an export
bug, when it last worked, and anything you already tried.
-->
