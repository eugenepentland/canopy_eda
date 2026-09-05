# Ward client

Client-only source from Eugene Pentland’s Ward repository, commit
`6d6c7c5d73cbc3b2322efed69862b45bbaca35a9`. These files were clean
in the source checkout when copied. The server, passkey implementation,
package manifest, build gate, and environment loader are not bundled.
`root.zig` exposes only the modules used by netlisp.

This keeps optional Ward hosting available without a sibling checkout or
a Ward server dependency for local users. Update these files together when
changing the Ward protocol; retain the client tests.

Compatibility patch: `http.zig` and `bearer_http.zig` use `timeout.zig`
to cancel the complete exchange after five seconds. The upstream socket
timeouts produced EAGAIN and crashed Zig 0.17's blocking-stream reader.
The real-listener smoke test covers a Ward listener that accepts connections
but stops answering, plus normal verification and explicit errors.
