# Guardian contract findings resolved — 2026-09-05

Base: `66fb227ee898c7931afb8130fc9af7f1c9e20994`.
The original Guardian audit identified 40 violations and 3 advisory rows across
29 functions, plus 16 accepted unguarded numeric conversions.

| Area | Original rows | Resolution |
| --- | ---: | --- |
| Durable writes | 8 | Four sidecar writers return errors; save/MCP callers propagate them before reporting a new revision. Sidecars use the shared atomic, fsynced writer. |
| Persistent reads | 2 advisory | Only FileNotFound produces an empty document; I/O errors, malformed JSON and invalid top-level rows stop replacement. Background cache writes also stop on failed reads. |
| Source mutations | 13 | One transaction capability holds a process mutex and directory flock over read-modify-write; nested CLI/core adapters share the hold. Source is parsed before atomic replacement. |
| Request decoding | 19 | A shared decoder validates fields, decodes escapes and rejects duplicate keys. Source serialization escapes decoded strings, and scanning existing values skips escaped quotes. |
| Instance identity | 1 advisory | Resolve a unique parsed source label with a content revision. Browser source edits carry revisions; stale edits return 409. Footprint selection uses the parsed component slot. |
| Numeric conversions | 16 | Replace unguarded casts with checked conversions; preserve integer precision for KiCad priorities. |

The checked-in JSON is a fresh, baseline-independent scan using the contracts
now enforced in `guardian.toml`: **0 violations and 1 advisory**. The advisory
is deliberately retained: Guardian cannot prove the semantics of the resolver
from a call name. It was reviewed against the implementation and regression
coverage for stale offsets, changed revisions, duplicate labels and comments.
It does not identify an additional confirmed defect.

The old external audit profile still refers to the removed `parseJsonString`
and substring-based target lookup; its two unmatched-operation notices indicate
retired selectors. The project policy names the replacement implementations.
No operation-contract findings were added to an accepted-debt baseline.

Verification includes HTTP source/notes revision tests, real threaded source
read-modify-write tests, missing/damaged/unreadable sidecar tests, failed commit
propagation, escaped-string decoding/selection, numeric conversion boundaries,
JavaScript syntax checks, and the existing sidecar and edit suites.

Metadata review: remove all 16 numeric baseline entries and refresh the public
API snapshot for the new decoder, transaction and error-returning store APIs.
The old global numeric budget of zero was unreachable while strict-path debt
returned early; after removing that debt, 53 pre-existing casts outside the
strict paths become visible. Their count is now frozen; strict-path protection
remains enabled with no accepted violations.

The source transaction serializes cooperating netlisp callers. Editors and
other processes that write files directly do not take its lock. Content revisions
reject browser requests whose source changed since the page was loaded.
