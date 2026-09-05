# occt-import-js 0.0.23 — licence drop (LGPL-2.1)

The STEP/IGES/BREP reader the 3D model pages load is **not** first-party code
and **not** permissively licensed. This directory carries its licences; the
two files it licenses live one level up, beside the first-party assets,
because `src/serve/static_assets.zig` embeds and serves them from there:

- `../../occt-import-js.js` — Emscripten JavaScript loader
- `../../occt-import-js.wasm` — the WebAssembly module (7.6 MB)

Both are **byte-for-byte verbatim** copies of `dist/` from the
`occt-import-js@0.0.23` npm package. Nothing in them was modified.

```text
Upstream:  https://github.com/kovacsv/occt-import-js  (kovacsv, Viktor Kovacs)
Package:   https://registry.npmjs.org/occt-import-js/-/occt-import-js-0.0.23.tgz
npm dist:  sha512-RFfYQXYFX5C1mB1Aywm0ShcUKzXOr/VzTnlzhBSDJOR6YCAPt1HYCzeXWg1vwwjn/cUxwqRNhhtf1dlewoZYCQ==
           sha1 1916aacd5b228e92da5de631ae048ca152281778
```

The exact vendored files are pinned by these SHA-256 digests:

```text
3fb44ce11d00611f9b3f3c5775d520ebab48930c1f08279b7b1316f05f0d3379  occt-import-js.js
33391fc9d94ea5c869a6718488bf0a9a464222bac9bdc764dfe1690cef281952  occt-import-js.wasm
```

## Licences

`occt-import-js` is licensed under the **GNU Lesser General Public License,
version 2.1** (`package.json` declares `"license": "LGPL-2.1"`). Its own
licence text is `license.occt-import-js.txt`, copied verbatim from the
package's `dist/`.

The WebAssembly module **statically embeds Open CASCADE Technology 7.6**
(the `occt` git submodule of the upstream repository, built with Emscripten).
OCCT is licensed under the **GNU Lesser General Public License, version 2.1,
with the Open CASCADE exception**:

- `license.occt.txt` — the LGPL-2.1 text as shipped in the package's `dist/`
- `OCCT_LGPL_EXCEPTION.txt` — the Open CASCADE exception, taken verbatim from
  `OCCT_LGPL_EXCEPTION.txt` at tag `V7_6_0` of the OCCT repository

## Where to obtain the corresponding source

- occt-import-js 0.0.23 — <https://github.com/kovacsv/occt-import-js> (tag
  `v0.0.23`), or the npm tarball named above, which contains the full source,
  `CMakeLists.txt` and the Emscripten build scripts used to produce these two
  files.
- Open CASCADE Technology 7.6 — <https://github.com/Open-Cascade-SAS/OCCT> at
  tag `V7_6_0`, or the upstream git remote the submodule points at,
  <https://git.dev.opencascade.org/repos/occt.git>. The official download page
  is <https://dev.opencascade.org/release>.

netlisp distributes both unmodified. `src/serve/static_assets.zig`
`@embedFile`s them and serves them at `/static/occt-import-js.js` and
`/static/occt-import-js.wasm`, so the bytes ride inside the executable as an
opaque blob — they are not linked into netlisp's native code and never run in
netlisp's process; the page fetches them and the browser's WebAssembly engine
executes them. Replacing them with a modified build needs no netlisp source
change: drop a different `occt-import-js.js`/`.wasm` pair into
`src/serve/assets/` and rebuild, or serve your own copy in front of
`/static/occt-import-js.wasm`.

**Keep these two files byte-for-byte upstream.** Editing them — even to add a
comment — makes this repository a distributor of a *modified* LGPL work, with
the extra change-marking and source-shipping duties that carries.

See `../../../../../THIRD_PARTY_NOTICES.md` for the whole picture.
