# Assembly rework guides

An assembly page can show bench rework or deviation guides stored beside its
design source. A design may keep as many as it needs — the legacy
`<design>.rework.md` plus any `<design>-<slug>.rework.md` companion:

```text
src/boards/example/example.sexp
src/boards/example/example.rework.md
src/boards/example/example-adf4159-bypass.rework.md
```

The `-` separator is required, so `example2-foo.rework.md` belongs to design
`example2` and never to `example`. Guides are listed with the legacy file first
and the rest in filename order; each is titled by its first `# ` heading, or by
its filename slug when it has none. An empty or unreadable file is skipped.

The guide is ordinary Markdown. Add interactive board targets inline with this
small DSL:

```text
[[uuid:0b42c42d-94e1-5fa1-a6b5-22bed47f9b63|R44]]
[[pin:0b42c42d-94e1-5fa1-a6b5-22bed47f9b63.1|R44 pad 1]]
[[net:LMX_VTUNE]]
```

The optional text after `|` changes the visible label without changing the
target. Component targets use the UUID derived from the part's stable source
identity and recorded in the design's `.bom` sidecar, so a guide remains
attached to the same physical part if annotation changes its refdes. A pin
target uses the final `.` to separate that UUID from its footprint pad number.

Legacy `[[ref:R44]]` and `[[pin:U17.16]]` targets remain readable for existing
guides, but new guides should always bind component and pad targets by UUID.

When at least one guide exists, the Assembly page carries a Guide tab next to
the normal Parts browser. The tab opens on a list of guide titles; clicking one
shows that guide alone, and "← All guides" returns to the list. A design with a
single guide opens it straight away, with the list one click behind the same
control. Clicking a target fits the board view to the matched component, pad, or
net. Pin targets mark only the requested footprint pad. A `?guide=<slug>` query
opens one guide directly, and a `?target=` deep link finds the guide that owns
it.

Guides are read-only in the web UI and remain useful as plain Markdown in Git.
