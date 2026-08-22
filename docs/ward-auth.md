# Auth (ward)

> Moved verbatim from CLAUDE.md (2026-08-19); linked from its Reference Docs section.

netlisp no longer runs its own auth — it is a **pure resource server**.
Authentication is delegated to **ward** (the `wardd` auth server, repo
`~/ai/ward`), which owns passkeys/WebAuthn, sessions, invites, roles, and is
the OAuth 2.1 authorization server. Public URL: **https://ward.eugenepentland.dev**
(local `http://127.0.0.1:9000`). The admin portal at
**https://ward.eugenepentland.dev/admin** manages users, sessions, invites,
OAuth clients, and grants; registration is invite-only through wardd. The
navbar Account link points at that admin portal.

- **Browser sessions.** A ward session cookie (domain `.eugenepentland.dev`) is
  verified against wardd `GET /verify`. No cookie → `302` to
  `https://ward.eugenepentland.dev/login?rd=<url>`; wardd unreachable → `503`
  (fail-closed, never fail-open).
- **MCP / API bearers.** Verified via wardd's LAN-only `POST /oauth/introspect`;
  the token scope must contain the service name (`eda`). On failure a `401`
  carries an RFC 9728 `WWW-Authenticate` pointing at
  `GET /.well-known/oauth-protected-resource` (the one well-known endpoint
  netlisp still serves), which names `ward.eugenepentland.dev` as the
  authorization server. Role mapping: ward **member → writer**, ward
  **admin → admin**, unknown → **reader** (write access gates the MCP mutation
  tools).
- **Plugin tokens (kept).** `eda_p_*` tokens — minted by the
  `mint-plugin-token` CLI, stored in `plugin_tokens.json` under the auth dir —
  still guard the KiCad plugin sync endpoint, checked **before** the ward
  bearer on `/api/sync-kicad-pcb/*`.
- **Dev bypass.** `NETLISP_DEV` grants a local admin identity to a loopback,
  unproxied request (env opt-in) — no wardd needed for local development.
- **Config (env / `.env`).** `WARD_VERIFY_URL`, `WARD_LOGIN_URL`,
  `WARD_INTROSPECT_URL`, `WARD_SERVICE_NAME` (default `eda`),
  `WARD_CACHE_TTL_SECS` (default `30`, the revocation-lag bound). Unset → fail
  closed (`503`) outside the dev bypass. Adapter: `src/serve/ward_auth.zig`
  (HTTP seam in `src/infra/net.zig`).

Everything netlisp used to host itself is **gone**: the `/account` page and
OAuth client minting (the `eda_c_*` / `eda_s_*` client-id/secret flow), all
`/auth/*` passkey/login/invite pages, all `/oauth/*` authorization-server
endpoints, `GET /.well-known/oauth-authorization-server`, the `mint-invite`
CLI, and the `users.json` / `sessions.json` / `credentials.json` /
`invites.json` / `oauth_clients.json` / `oauth_tokens.json` sidecars.
