# ⚠ `zt` carries no licence — upstream grants no redistribution rights

**This directory has no `LICENSE` file because upstream has none.** There is
nothing to copy here. Read this before shipping, forking or repackaging
netlisp.

`vendor/zt/` is a verbatim vendoring of

    https://github.com/lalinsky/zt
    revision a8b94373999c2483efa5f646438263785f70743d (branch `main`)

and that repository publishes **no licence of any kind**. Checked
2026-09-05:

| Evidence | Result |
| --- | --- |
| `GET /repos/lalinsky/zt/license` | `404 Not Found` |
| `GET /repos/lalinsky/zt` → `.license` | `null` |
| Git tree at `a8b94373…`, recursive (59 entries) | no `LICENSE`, `LICENSE.*`, `COPYING`, `NOTICE` or `LEGAL` file |
| Repository root at `main` (HEAD) | same 11 top-level entries; still no licence file |
| `README.md` (both revisions) | no licence section, no SPDX identifier |
| `build.zig.zon` | no licence field (Zig's manifest has none) |

Its own README calls the project "still an experimental project".

## What that means

Without a licence grant, the default of copyright law applies: the author
retains all rights, and **no one else has permission to copy, modify or
redistribute the code** — vendoring it into this tree included. netlisp is
MIT-licensed, but netlisp's licence cannot grant rights over someone else's
code, so this directory is *not* covered by the repository's `LICENSE`.

`zt` is not optional and not build-time-only: `build.zig` compiles
`src/serve/templates/*.zt` with it *and* imports its runtime module into the
`netlisp` executable (`exe_mod.addImport("zt", …)`), so a shipped binary
contains `zt` code.

## Resolving this

One of, in order of preference:

1. **Ask upstream to license it.** A one-line MIT/0BSD `LICENSE` file (or a
   written grant recorded here) closes this outright. Open an issue at
   <https://github.com/lalinsky/zt/issues>.
2. **Replace it.** The templates are the only consumer; a first-party
   compile-time template step or another permissively licensed Zig templating
   package removes the dependency.
3. **Drop the dependency** and emit the three pages from Zig directly.

Until one of those lands, `THIRD_PARTY_NOTICES.md` records this as the one
component of netlisp whose licence could not be established, and a public
release of the tree ships code it has no demonstrated right to redistribute.
