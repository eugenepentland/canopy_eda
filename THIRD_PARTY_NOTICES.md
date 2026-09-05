# Third-Party Notices

netlisp itself is MIT-licensed — see [`LICENSE`](LICENSE). This file covers
**everything in this repository that someone else wrote**: what it is, which
revision, under what licence, where it came from, where it lives here, and the
licence text (inline when short, or a pointer to the file that carries it).

It is grouped by how the code reaches a user:

- **[Part 1 — Shipped](#part-1--shipped)**: compiled into the `netlisp`
  binary or served to browsers by it. These notices travel with any
  distribution of netlisp, source or binary.
- **[Part 2 — Build-time only](#part-2--build-time-only)**: needed to build or
  check netlisp, never redistributed as part of it.

Two things stand out and are stated up front rather than buried:

> ⚠ **`vendor/zt` has no licence at all.** Its upstream
> (<https://github.com/lalinsky/zt>) publishes no `LICENSE`, at the pinned
> revision or at HEAD, so nobody has demonstrated permission to redistribute
> it — and its code is linked into the `netlisp` executable. See
> [zt](#zt-no-licence) and [`vendor/zt/LICENSE-MISSING.md`](vendor/zt/LICENSE-MISSING.md).

> ⚠ **`occt-import-js` and the OpenCASCADE it embeds are LGPL-2.1, not
> permissive.** They are served to browsers as two unmodified files. See
> [occt-import-js + OCCT](#occt-import-js--open-cascade-technology).

## At a glance

| Component | Version / revision | Licence (SPDX) | Where it lives | Shipped? |
| --- | --- | --- | --- | --- |
| [three.js](#threejs) | r128 | `MIT` | `src/serve/assets/three.min.js` | browser |
| [three.js OrbitControls](#threejs-orbitcontrols) | r128 | `MIT` | `src/serve/assets/OrbitControls.js` | browser |
| [Mapbox earcut](#mapbox-earcut) | 2.2.2 (via three.js r128) | `ISC` | `src/serve/assets/pcb_earcut.js` | browser |
| [CodeMirror 5](#codemirror-5) | 5.65.16 | `MIT` | `src/serve/assets/codemirror.bundle.js`, `codemirror.css` | browser |
| [PDF.js](#pdfjs) | 4.10.38 | `Apache-2.0` | `src/serve/assets/vendor/pdfjs-4.10.38/` | browser |
| [occt-import-js](#occt-import-js--open-cascade-technology) | 0.0.23 | `LGPL-2.1-only` | `src/serve/assets/occt-import-js.{js,wasm}` | browser |
| [Open CASCADE Technology](#occt-import-js--open-cascade-technology) | 7.6 (inside the wasm) | `LGPL-2.1-only` **+ OCCT exception** | `src/serve/assets/occt-import-js.wasm` | browser |
| [http.zig (`httpz`)](#httpz-httpzig) | `e6c23eb9` | `MIT` | `vendor/httpz/` | binary |
| [websocket.zig](#websocketzig) | `3318a78a` | `MIT` | `vendor/httpz/deps/websocket/` | binary |
| [metrics.zig](#metricszig) | `21fe85ea` | `MIT` | `vendor/httpz/deps/metrics/` | binary |
| [zt](#zt-no-licence) | `a8b94373` | **none — unresolved** | `vendor/zt/` | binary |
| [Hershey Simplex fonts](#hershey-simplex-vector-fonts) | 1967 data | public-domain data, acknowledgement required | `src/silk_font.zig`, `src/serve/assets/pcb_board.js` | binary + browser |
| [Adobe Core 14 AFM metrics](#adobe-core-14-afm-font-metrics) | Core14 AFMs (1997) | Adobe AFM redistribution notice | `src/pdf_afm.zig` | binary |
| [Zig standard library](#zig-standard-library) | 0.17.0-dev.1683+5ceec001b | `MIT` | linked from the compiler | binary |
| [Guardian (`guardian-zig`)](#guardian-guardian-zig) | v0.2.1 | `MIT` | fetched by `build.zig.zon` | build only |
| [Zig compiler toolchain](#zig-compiler-toolchain) | 0.17.0-dev.1683+5ceec001b | `MIT` | not vendored | build only |
| [Playwright](#playwright) | 1.62.1 | `Apache-2.0` | `package.json` devDependency | dev only |

---

# Part 1 — Shipped

Everything in this part is either compiled into the `netlisp` executable or
served by it to a browser at `/static/…`.

## three.js

| | |
| --- | --- |
| **Version** | r128 |
| **Licence** | `MIT` |
| **Copyright** | Copyright © 2010-2021 three.js authors |
| **Upstream** | <https://github.com/mrdoob/three.js> |
| **In this tree** | `src/serve/assets/three.min.js` (served at `/static/three.min.js`) |
| **Modified** | No — upstream minified build, unmodified |

Powers the 3D model viewer, the PCB 3D view and the STEP-export preview.
The file carries its own `@license` banner; version identified from the
`const e = "128"` release constant inside the bundle.
`sha256 9274bbcec8d96168626c732b5d31c775aa8cfb7eaa0599bec0c175908a2c1ce2`.

```text
The MIT License

Copyright © 2010-2021 three.js authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## three.js OrbitControls

| | |
| --- | --- |
| **Version** | r128 (`examples/js/controls/OrbitControls.js`) |
| **Licence** | `MIT` — same licence and holders as three.js above |
| **Upstream** | <https://github.com/mrdoob/three.js/blob/r128/examples/js/controls/OrbitControls.js> |
| **In this tree** | `src/serve/assets/OrbitControls.js` (served at `/static/OrbitControls.js`) |
| **Modified** | Only a licence banner was prepended |

Upstream ships this file with **no** per-file notice — nothing was stripped
here. Because the file is served on its own URL, a `@license` banner was added
so the notice travels with it. Everything below that banner is byte-for-byte
the r128 release: `sha256 02bb4ade710f3e607329e37a21f098bc3ac70eb6e33daf8a65e79f4db785e7b2`,
verified against the upstream raw file.

Licence text: identical to [three.js](#threejs) above.

## Mapbox earcut

| | |
| --- | --- |
| **Version** | earcut 2.2.2, as ported into three.js r128 (`src/extras/Earcut.js`) |
| **Licence** | `ISC` |
| **Copyright** | Copyright (c) 2016, Mapbox |
| **Upstream** | <https://github.com/mapbox/earcut> |
| **In this tree** | `src/serve/assets/pcb_earcut.js` (served at `/static/pcb_earcut.js`) |
| **Modified** | Extracted from the three.js bundle so the 2D PCB page need not load all of three.js; the algorithm is unmodified |

three.js r128's `Earcut.js` states `Port from https://github.com/mapbox/earcut
(v2.2.2)`, which is where the version comes from. The file carries its own
attribution header.

```text
ISC License

Copyright (c) 2016, Mapbox

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

## CodeMirror 5

| | |
| --- | --- |
| **Version** | 5.65.16 |
| **Licence** | `MIT` |
| **Copyright** | Copyright (C) 2017 by Marijn Haverbeke <marijn@haverbeke.berlin> and others |
| **Upstream** | <https://codemirror.net/5/> · <https://github.com/codemirror/codemirror5> |
| **In this tree** | `src/serve/assets/codemirror.bundle.js`, `src/serve/assets/codemirror.css` |
| **Modified** | Minified and concatenated; a licence header was **restored** (see below) |

The source editor in the schematic viewer. `codemirror.bundle.js` is a
minified concatenation of four unmodified 5.65.16 files, in this order:

1. `lib/codemirror.js`
2. `mode/scheme/scheme.js`
3. `addon/edit/matchbrackets.js`
4. `addon/edit/closebrackets.js`

`codemirror.css` is the minified `lib/codemirror.css` from the same release.

**Evidence for the version and contents.** The bundle sets
`p.version = "5.65.16"` at the end of the core UMD wrapper; the three
following segments are UMD wrappers that `require("../../lib/codemirror")` and
respectively call `defineMode("scheme", …)`, implement the bracket-matching
helpers, and `defineOption("autoCloseBrackets", …)`. The CSS was compared
rule-by-rule against `codemirror@5.65.16`'s `lib/codemirror.css` from npm: every
upstream rule is present with the same declarations, differing only in
minifier rewrites (`black` → `#000`, dropped trailing semicolons, and
identical-declaration rules merged, which is why upstream's 106 rule blocks
become 96).

**The header had been stripped.** Upstream prefixes every one of those four
files with

```js
// CodeMirror, copyright (c) by Marijn Haverbeke and others
// Distributed under an MIT license: https://codemirror.net/5/LICENSE
```

and the minifier dropped all four copies — the bundle as committed contained
no occurrence of `Marijn`, `codemirror.net` or `license`. A `/*! … */` banner
carrying that notice has been restored at the top of both files.

```text
MIT License

Copyright (C) 2017 by Marijn Haverbeke <marijn@haverbeke.berlin> and others

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## PDF.js

| | |
| --- | --- |
| **Version** | 4.10.38 (`pdfjs-dist`) |
| **Licence** | `Apache-2.0` |
| **Copyright** | Copyright 2024 Mozilla Foundation |
| **Upstream** | <https://github.com/mozilla/pdf.js> |
| **In this tree** | `src/serve/assets/vendor/pdfjs-4.10.38/` — `pdf.min.mjs`, `pdf.worker.min.mjs` |
| **Modified** | No — verbatim copies from the npm tarball |

Renders datasheets and review PDFs in the browser. The bundles keep their
upstream licence notices, and the complete Apache-2.0 text ships beside them:

- **Licence text:** [`src/serve/assets/vendor/pdfjs-4.10.38/LICENSE`](src/serve/assets/vendor/pdfjs-4.10.38/LICENSE)
- **Provenance, tarball integrity and per-file SHA-256 digests:**
  [`src/serve/assets/vendor/pdfjs-4.10.38/README.md`](src/serve/assets/vendor/pdfjs-4.10.38/README.md)

## occt-import-js + Open CASCADE Technology

> ⚠ **This is the one shipped component that is copyleft.** Read this entry
> before repackaging netlisp.

| | |
| --- | --- |
| **Version** | occt-import-js 0.0.23, statically embedding Open CASCADE Technology 7.6 |
| **Licence** | occt-import-js: `LGPL-2.1-only`. OCCT: `LGPL-2.1-only` **with the Open CASCADE exception** |
| **Copyright** | Viktor Kovacs (occt-import-js); OPEN CASCADE SAS and contributors (OCCT) |
| **Upstream** | <https://github.com/kovacsv/occt-import-js> · <https://github.com/Open-Cascade-SAS/OCCT> |
| **In this tree** | `src/serve/assets/occt-import-js.js`, `src/serve/assets/occt-import-js.wasm` |
| **Modified** | No — byte-for-byte the `dist/` files of `occt-import-js@0.0.23` |

The STEP/IGES/BREP reader behind the 3D model pages. It is **not** MIT: the
package declares `"license": "LGPL-2.1"`, and the WebAssembly module has all
of OpenCASCADE 7.6 compiled into it (the wasm's own strings identify
`Open CASCADE 7.6` and the `occt/src/…` build paths).

**Version determined by hashing.** The two committed files match the npm
tarball `occt-import-js-0.0.23.tgz` exactly:

```text
3fb44ce11d00611f9b3f3c5775d520ebab48930c1f08279b7b1316f05f0d3379  occt-import-js.js
33391fc9d94ea5c869a6718488bf0a9a464222bac9bdc764dfe1690cef281952  occt-import-js.wasm
```

(0.0.22's files hash differently, so the pin is unambiguous.)

**Licence texts**, in
[`src/serve/assets/vendor/occt-import-js-0.0.23/`](src/serve/assets/vendor/occt-import-js-0.0.23/):

- [`license.occt-import-js.txt`](src/serve/assets/vendor/occt-import-js-0.0.23/license.occt-import-js.txt)
  — LGPL-2.1, occt-import-js's own licence, verbatim from the package
- [`license.occt.txt`](src/serve/assets/vendor/occt-import-js-0.0.23/license.occt.txt)
  — LGPL-2.1 as the package ships it for OCCT
- [`OCCT_LGPL_EXCEPTION.txt`](src/serve/assets/vendor/occt-import-js-0.0.23/OCCT_LGPL_EXCEPTION.txt)
  — the Open CASCADE exception, verbatim from OCCT tag `V7_6_0`
- [`README.md`](src/serve/assets/vendor/occt-import-js-0.0.23/README.md)
  — provenance and the source-availability statement

**Open CASCADE exception (verbatim):**

```text
Open CASCADE exception (version 1.0) to GNU LGPL version 2.1.

The object code (i.e. not a source) form of a "work that uses the Library"
can incorporate material from a header file that is part of the Library.
As a special exception to the GNU Lesser General Public License version 2.1,
you may distribute such object code incorporating material from header files
provided with the Open CASCADE Technology libraries (including code of CDL
generic classes) under terms of your choice, provided that you give
prominent notice in supporting documentation to this code that it makes use
of or is based on facilities provided by the Open CASCADE Technology software.
```

**Where to obtain the corresponding source.** OCCT 7.6 source is available
from <https://github.com/Open-Cascade-SAS/OCCT> at tag `V7_6_0`, from the
upstream git remote <https://git.dev.opencascade.org/repos/occt.git> that
occt-import-js's `occt` submodule points at, and from Open CASCADE's release
page <https://dev.opencascade.org/release>. occt-import-js's own source,
including the CMake and Emscripten scripts that produced these exact two
files, is at <https://github.com/kovacsv/occt-import-js> (tag `v0.0.23`) and
inside the npm tarball named above.

**How the LGPL obligations are met here.** netlisp redistributes both files
unmodified, gives this prominent notice, ships the full LGPL-2.1 text and the
OCCT exception, and names above where the corresponding source is obtained.

Be precise about how they travel: `src/serve/static_assets.zig` `@embedFile`s
both and serves them at `/static/occt-import-js.js` and
`/static/occt-import-js.wasm`, so the bytes ride inside the `netlisp`
executable as an opaque blob. They are **not** linked into netlisp's native
code and never execute in netlisp's process — the page fetches them and the
browser's own WebAssembly engine runs them. Replacing them with a modified
OCCT build therefore needs no netlisp source change: drop a different
`occt-import-js.js`/`.wasm` pair into `src/serve/assets/` and rebuild (netlisp
is MIT, so its source is available for exactly that), or serve a replacement
in front of `/static/occt-import-js.wasm`.

Keep both files byte-for-byte upstream. Editing them — even to add a comment
— makes netlisp a distributor of a *modified* LGPL work, with the extra
change-marking and source-shipping duties that carries.

## httpz (http.zig)

| | |
| --- | --- |
| **Revision** | `e6c23eb959e20bc8871184622fa9082ddaf5b106` (branch `dev`) |
| **Licence** | `MIT` |
| **Copyright** | Copyright (c) 2024 Karl Seguin. |
| **Upstream** | <https://github.com/karlseguin/http.zig> |
| **In this tree** | `vendor/httpz/` |
| **Modified** | Yes — a small port to the pinned Zig 0.17 snapshot (~270 changed lines across `src/httpz.zig`, `response.zig`, `router.zig`, `testing.zig`, `windows.zig`, `worker.zig`, plus the manifest and two examples) |

The HTTP server. Vendored, not fetched, so the build is offline and the
revision is exact — see [`vendor/README.md`](vendor/README.md).

- **Licence text:** [`vendor/httpz/LICENSE`](vendor/httpz/LICENSE), verified
  byte-identical to upstream's `LICENSE` at the pinned revision.

## websocket.zig

| | |
| --- | --- |
| **Revision** | `3318a78a2c3d3b972c394717c43a354d0feb8b91` (branch `dev`) |
| **Licence** | `MIT` |
| **Copyright** | Copyright (c) 2024 Karl Seguin. |
| **Upstream** | <https://github.com/karlseguin/websocket.zig> |
| **In this tree** | `vendor/httpz/deps/websocket/` |
| **Modified** | Yes — trimmed (CI, Makefile, Dockerfile, test runner and support files dropped) and ported to the pinned Zig snapshot (~60 changed lines in `src/proto.zig`, `src/server/server.zig`, `src/windows.zig`) |

The revision httpz itself selects, vendored with it.

**The `LICENSE` file was missing** from this directory — upstream carries one
at the pinned revision and the trimmed vendoring dropped it. It has been
restored: [`vendor/httpz/deps/websocket/LICENSE`](vendor/httpz/deps/websocket/LICENSE),
fetched from
`https://raw.githubusercontent.com/karlseguin/websocket.zig/3318a78a2c3d3b972c394717c43a354d0feb8b91/LICENSE`.

## metrics.zig

| | |
| --- | --- |
| **Revision** | `21fe85eaa1761a870753a4d0b9e3f289986ac1a3` |
| **Licence** | `MIT` |
| **Copyright** | Copyright (c) 2024 Karl Seguin. |
| **Upstream** | <https://github.com/karlseguin/metrics.zig> |
| **In this tree** | `vendor/httpz/deps/metrics/` |
| **Modified** | Yes — ported to the pinned Zig snapshot (~180 changed lines, mostly `src/metrics.zig` and `src/metric.zig`) |

- **Licence text:** [`vendor/httpz/deps/metrics/LICENSE`](vendor/httpz/deps/metrics/LICENSE),
  verified byte-identical to upstream's at the pinned revision.

### The Karl Seguin MIT text (all three packages)

```text
Copyright (c) 2024 Karl Seguin.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## zt (no licence)

| | |
| --- | --- |
| **Revision** | `a8b94373999c2483efa5f646438263785f70743d` (branch `main`) |
| **Licence** | **None. Upstream publishes no licence of any kind.** |
| **Upstream** | <https://github.com/lalinsky/zt> |
| **In this tree** | `vendor/zt/` |
| **Modified** | Yes — ported to the pinned Zig snapshot (~350 changed lines in `src/ast.zig`, `codegen.zig`, `main.zig`, `parser.zig`, plus build files) |

The HTML template language that compiles `src/serve/templates/*.zt` into Zig.
It is **not** build-time only: `build.zig` also does
`exe_mod.addImport("zt", …)`, so its runtime module is compiled into the
shipped `netlisp` executable.

**Verified 2026-09-05, and this is a blocker, not an oversight:**

- `GET /repos/lalinsky/zt/license` → `404 Not Found`
- the repository record's `license` field is `null`
- the full recursive git tree at `a8b94373…` (59 entries) contains no
  `LICENSE`, `LICENSE.*`, `COPYING`, `NOTICE` or `LEGAL` file
- the repository root at `main` (HEAD) has the same 11 top-level entries — no
  licence file there either
- neither `README.md` nor `build.zig.zon` states a licence or an SPDX id

With no grant, the author retains all rights and **no one — this repository
included — has demonstrated permission to copy, modify or redistribute this
code.** netlisp's MIT licence cannot cover it, so `vendor/zt/` is explicitly
outside the scope of [`LICENSE`](LICENSE).

Details and the three ways out (ask upstream to license it, replace it, or
drop it) are in [`vendor/zt/LICENSE-MISSING.md`](vendor/zt/LICENSE-MISSING.md).

## Hershey Simplex vector fonts

| | |
| --- | --- |
| **Version** | The classic 95-glyph ASCII Simplex array (data first published 1967) |
| **Licence** | Public-domain coordinate data, redistributable subject to the acknowledgement below |
| **Copyright** | Copyright: 1967 Dr. A. V. Hershey, James Hurt |
| **Upstream** | The Hershey font distribution (originally via USENIX); e.g. <https://github.com/kamalmostafa/hershey-fonts> |
| **In this tree** | `src/silk_font.zig` (Zig glyph table) and the `SILK_FONT` table in `src/serve/assets/pcb_board.js` (the same data, kept identical by a test) |
| **Modified** | Reformatted: coordinates transcribed into a Zig array and a JSON object, y-down, with a pen-up sentinel |

The single-stroke face used for fabricated silkscreen text. It is drawn into
Gerber output, so the data reaches boards as well as screens. The
acknowledgement the distribution requires, reproduced verbatim:

```text
Copyright: 1967 Dr. A. V. Hershey, James Hurt

This distribution of the Hershey Fonts may be used by anyone for
any purpose, commercial or otherwise, providing that:
	1. The following acknowledgements must be distributed with
		the font data:
		- The Hershey Fonts were originally created by Dr.
			A. V. Hershey while working at the U. S.
			National Bureau of Standards.
		- The format of the Font data in this distribution
			was originally created by
				James Hurt
				Cognition, Inc.
				900 Technology Park Drive
				Billerica, MA 01821
				(mit-eddie!ci-dandelion!hurt)
	2. The font data in this distribution may be converted into
		any other format *EXCEPT* the format distributed by
		the U.S. NTIS (which organization holds the rights
		to the distribution and use of the font data in that
		particular format). Not that anybody would really
		*want* to use their format... each point is described
		in eight bytes as "xxx yyy:", where xxx and yyy are
		the coordinate values as ASCII numbers.
```

Netlisp does not distribute the font data in the U.S. NTIS format that clause
2 excludes.

## Adobe Core 14 AFM font metrics

| | |
| --- | --- |
| **Version** | Adobe Core 14 AFM files (`Helvetica.afm`, `Helvetica-Bold.afm`, AFM 4.1, dated 1997) |
| **Licence** | Adobe's AFM redistribution notice, below |
| **Copyright** | Copyright (c) 1985, 1987, 1989, 1990, 1997 Adobe Systems Incorporated. All Rights Reserved. |
| **Upstream** | Adobe's Core 14 AFM distribution (`Core14_AFMs`, with `MustRead.html`) |
| **In this tree** | `src/pdf_afm.zig` — the `helvetica_widths` and `helvetica_bold_widths` tables |
| **Modified** | Transcribed, not copied: the advance widths were re-indexed from AFM glyph names to WinAnsi codes and written as two `[256]u16` Zig arrays. No AFM file is present in this tree and no font program is embedded in any output. |

netlisp's PDF writer measures text in the base-14 faces every PDF reader
already has. Courier's 600/1000-em advance is a single constant; the two
Helvetica tables are Adobe's published metrics. (Spot-checked against
`Helvetica.afm`: `A` 667, `a` 556, `space` 278, `W` 944, `i` 222, `m` 833;
quoteleft/quoteright 222, quotedblleft/quotedblright 333, bullet 350,
endash 556, emdash 1000 — all matching at their WinAnsi codes.)

Adobe's notice, verbatim from `MustRead.html` in the Core 14 AFM
distribution:

```text
This file and the 14 PostScript(R) AFM files it accompanies may be used,
copied, and distributed for any purpose and without charge, with or without
modification, provided that all copyright notices are retained; that the AFM
files are not distributed without this file; that all modifications to this
file or any of the AFM files are prominently noted in the modified file(s);
and that this paragraph is not modified. Adobe Systems has no responsibility
or obligation to support the use of the AFM files.
```

The transcription is a modification of that data, and is noted as such here
and in the header comment of `src/pdf_afm.zig`.

## Zig standard library

| | |
| --- | --- |
| **Version** | The `std` shipped with Zig `0.17.0-dev.1683+5ceec001b` (see [`.zigversion`](.zigversion)) |
| **Licence** | `MIT` (Expat) |
| **Copyright** | Copyright (c) Zig contributors |
| **Upstream** | <https://github.com/ziglang/zig> |
| **In this tree** | Not vendored — compiled in from the toolchain |
| **Modified** | No |

Every Zig source file here imports `std`, so parts of it are linked into the
shipped binary. Notable users include `std.hash.Crc32` and `std.hash.Adler32`
(the PNG and gzip checksums) and `std.compress.flate.Decompress`.

```text
The MIT License (Expat)

Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

# Part 2 — Build-time only

Needed to build, gate or measure netlisp. None of it is redistributed as part
of the tool.

## Guardian (`guardian-zig`)

| | |
| --- | --- |
| **Version** | v0.2.1 |
| **Licence** | `MIT` |
| **Copyright** | Copyright (c) 2026 Eugene Pentland |
| **Upstream** | <https://github.com/eugenepentland/guardian-zig> |
| **In this tree** | Not vendored — fetched by URL + hash from [`build.zig.zon`](build.zig.zon) into Zig's global package cache |
| **Modified** | No |

The code-quality gate that runs on every `zig build`. It is the only network
dependency of the build; the first build downloads
`guardian-zig/archive/refs/tags/v0.2.1.tar.gz` (hash
`guardian-0.2.1-Qv8iu_GLPQBNOe5Zp3pE9AGxcf6Bxfm4dtwCaa6iaYyN`) and every later
build is offline. It gates the build; it is not linked into `netlisp`.

```text
MIT License

Copyright (c) 2026 Eugene Pentland

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Zig compiler toolchain

| | |
| --- | --- |
| **Version** | `0.17.0-dev.1683+5ceec001b`, exactly (see [`.zigversion`](.zigversion), [`ZIG_TOOLCHAIN.md`](ZIG_TOOLCHAIN.md)) |
| **Licence** | `MIT` (Expat) — the same text as [Zig standard library](#zig-standard-library) |
| **Upstream** | <https://ziglang.org> · <https://github.com/ziglang/zig> |
| **In this tree** | Not vendored. `scripts/install-zig.sh` downloads and verifies it against `scripts/zig-toolchain.sha256` |

## Playwright

| | |
| --- | --- |
| **Version** | 1.62.1 |
| **Licence** | `Apache-2.0` |
| **Upstream** | <https://github.com/microsoft/playwright> |
| **In this tree** | A `devDependency` in [`package.json`](package.json) / [`package-lock.json`](package-lock.json). Not vendored, not installed by `zig build`, not shipped |

Drives the optional headless-browser performance and invariant harnesses under
`scripts/`. Node.js and Python are likewise developer prerequisites, not
redistributed components.

---

# What is *not* third-party

Checked while compiling this file, because "hand-written per the spec" is a
claim worth recording evidence for:

- **`src/deflate.zig` and `src/png.zig`** — a DEFLATE compressor, gzip wrapper
  and PNG encoder written from the RFCs. The only tables are RFC 1951's
  length/distance code tables and the fixed-Huffman assignment, which are the
  wire format itself, not someone's code; the CRC-32 and Adler-32
  implementations come from `std.hash`. No borrowed source.
- **`src/font5x7.zig`** — the 5×7 diagnostic bitmap font is authored here as
  ASCII-art grids, glyph by glyph. (The *silkscreen* font is a different file
  and is third-party — see [Hershey](#hershey-simplex-vector-fonts).)
- **`stdlib/`** — the bundled component, footprint and pinout library. Every
  land pattern is computed from the IPC-7351B density-level-B equations over
  published package dimensions, and each file's header states the dimensions
  and equations so the numbers can be re-derived. Nothing is copied from
  another component library; see `stdlib/README.md`.
- **`test/fixtures/`** — the PDF-viewer workload is generated by
  `test/fixtures/browser_perf/generate_datasheet.js` ("no third-party fixture
  bytes"), and `route-review.kicad_pcb` is emitted by netlisp itself
  (`(generator "netlisp-browser-perf")`). No vendor datasheet or third-party
  board is redistributed.
- **`scripts/`** — first-party. The browser harnesses (`pcb_editor_perf`,
  `pcb_browser_perf`, `ui_browser_perf`, `pcb_editor_invariants`, …) drive
  Playwright but contain no vendored code.
- **`src/serve/assets/drc.wasm`** — compiled from this repository's own Zig
  source by `zig build wasm-drc`.
- **`src/serve/assets/board_review_checklist.md`** — original prose. It quotes
  and cites standards bodies and vendor application notes (IPC, IEC, Infineon)
  in short attributed fragments; it reproduces no standard.

# KiCad

netlisp **writes and reads KiCad file formats** — netlists, footprints,
`.kicad_sch` and `.kicad_pcb` — so that a design can be handed to KiCad's PCB
editor and brought back. It contains no KiCad source code and **bundles no
KiCad library content**: no KiCad symbol, footprint, 3D model or template file
is copied into this repository, and none is required to build or run netlisp.
The formats are implemented from their published structure, and every footprint
netlisp ships is its own (see `stdlib/`, above). KiCad is a separate program
under the GPL; netlisp neither links against it nor redistributes it.

# Reporting a problem with this file

If something here is wrong, incomplete, or names your work without the notice
your licence requires, please open an issue at
<https://github.com/eugenepentland/netlisp>.
