# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| `main` | Yes — fixes land here first |
| latest tagged release | Yes |
| anything older | No |

netlisp is developed by a single maintainer. There are no long-term support
branches and no backports: a fix goes onto `main` and into the next tag.

## The threat model, in plain words

Read [docs/auth.md](docs/auth.md) for the mechanism. The short version:

**netlisp is a local tool with no authentication of its own.** `netlisp serve`
binds `127.0.0.1` and treats any loopback request that did not pass through a
reverse proxy as an **admin**. There is no user database, no session store, no
password. Everything else gets a `403`.

That has three consequences worth stating out loud:

1. **Anything on your machine that can open `http://127.0.0.1:7050` has full
   write authority** — every design edit, board rewrite, export and release
   attestation. That includes another local process, and it includes a web page
   in your browser making a request to localhost. Locality is derived from the
   TCP peer address, never from a request header, precisely because a header is
   attacker-controlled.
2. **netlisp parses untrusted input with hand-written code.** Design `.sexp`
   files, imported `.kicad_pcb` and `.kicad_sym` boards and symbols, PNG, ZIP,
   DEFLATE streams and PDFs all go through codecs in this repository. Several
   carry fuzz harnesses (`[fuzz_presence]` in `guardian.toml` lists which), but
   a file you did not write is input you should not fully trust.
3. **`--allow-remote` turns the only gate off.** It makes *every* request an
   admin, authenticating nobody. It exists for the case where an authenticating
   reverse proxy sits in front and is doing the authentication for you. Widening
   `--bind` without it is safe-but-useless; setting it without a proxy in front
   publishes an unauthenticated admin API. **Exposure beyond loopback is the
   operator's responsibility.**

The one narrower credential is the plugin bearer token
(`netlisp mint-plugin-token`), which admits `POST /api/sync-kicad-pcb/:name` and
nothing else. It rewrites a board file in place and never expires, so treat it
as durable board-write capability; revoke by removing its hash from
`plugin_tokens.json`.

## What counts as a vulnerability

Please report any of these privately:

- **Escalation through a loopback request.** Anything a *different* local
  process — or a page loaded in the user's browser — can make netlisp do beyond
  what the local-admin model already grants: reading or writing files outside
  the project, running a command, exfiltrating data to a third party, or a
  cross-origin request the browser will send that mutates state.
- **Path traversal or symlink escape.** Any input (a design name, a route
  parameter, a path inside an imported archive, a library reference) that reads
  or writes a file outside `--project-dir` and the configured library
  directories.
- **Memory safety in a parser.** Out-of-bounds access, use-after-free, an
  unchecked cast, or an unbounded allocation reached from hostile bytes in the
  S-expression parser, the KiCad readers, DEFLATE, ZIP, PNG or PDF paths.
- **Crash, hang or resource exhaustion in the server** on hostile input — a
  request or file that takes the running server down or wedges it.
- **Credential handling** — a plugin token, cached download or auth-directory
  file written world-readable, logged, or leaked into an export.

## What is not a vulnerability

These are documented, intentional behavior. They are worth an issue if the
documentation is unclear, but not a security report:

- Loopback being admin by default, and everything that follows from it.
- `--allow-remote` making every request an admin. That is what the flag does.
- Running the server on a public interface without an authenticating proxy in
  front of it.
- A one-shot CLI command crashing on a malformed file you handed it. That is a
  bug — please file it as one — but the CLI has your privileges either way.
- Anything that assumes the attacker can already run code as you or write into
  your project directory.

## Reporting

**Do not open a public issue for a vulnerability.**

Report privately through GitHub: go to the repository's **Security** tab and
choose **Report a vulnerability**. That opens a private advisory visible only to
the maintainers, and it is the only supported channel — there is no security
email address.

Please include:

- what an attacker gains, and what access they need to start;
- the version: the output of `netlisp version`, plus the commit if you built
  from source;
- your OS, and how the server was started (flags, `--project-dir`, whether a
  proxy was in front);
- a minimal reproducer — a `.sexp`, an input file, or a `curl` command.

## What to expect

This is a single-maintainer project and response is **best effort**, with no
SLA. Realistically: an acknowledgement within about a week, and a fix on `main`
as soon as one is understood, prioritised by how much access the issue actually
gives an attacker.

Please give the maintainer a reasonable window to ship a fix before publishing
details. Reporters are credited in the advisory and the changelog unless they
ask not to be.
