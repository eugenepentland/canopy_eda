const status = document.getElementById('status');
function fmtDate(ts){if(!ts)return 'Unknown';return new Date(ts*1000).toLocaleString()}
async function refreshPasskeys(){
  const r = await fetch('/auth/credentials/list');
  if (!r.ok) return; // probably not logged in with a real session
  const data = await r.json();
  const list = document.getElementById('passkey-list');
  list.innerHTML = '';
  for (const c of data.credentials) {
    const row = document.createElement('div'); row.className = 'row';
    const meta = document.createElement('div');
    const title = document.createElement('div'); title.textContent = 'Passkey';
    const added = document.createElement('div'); added.className = 'meta'; added.textContent = 'Added ' + fmtDate(c.created_at);
    meta.appendChild(title); meta.appendChild(added);
    const btn = document.createElement('button'); btn.className='btn-danger'; btn.textContent = 'Delete';
    btn.onclick = async () => {
      if (data.credentials.length <= 1) { status.className='status error'; status.textContent='Cannot delete your only passkey. Add another first.'; return; }
      if (!confirm('Delete this passkey?')) return;
      const rr = await fetch('/auth/credentials/delete', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({id:c.id})});
      const j = await rr.json();
      if (j.ok) refreshPasskeys(); else { status.className='status error'; status.textContent = j.error || 'Delete failed'; }
    };
    row.appendChild(meta); row.appendChild(btn); list.appendChild(row);
  }
  if (data.credentials.length === 0) list.innerHTML = '<p class="muted">No passkeys yet.</p>';
}
document.getElementById('logout-btn').onclick = async () => {
  await fetch('/auth/logout', {method:'POST'}); window.location.href = '/auth/login';
};
document.getElementById('add-passkey-btn').onclick = async () => {
  status.className = 'status'; status.textContent = 'Requesting challenge...';
  try {
    const cr = await fetch('/auth/register/challenge');
    const opts = await cr.json();
    if (!cr.ok) throw new Error(opts.error || 'Challenge failed');
    const publicKey = {
      challenge: b64urlToBytes(opts.challenge), rp: opts.rp,
      user: { id: b64urlToBytes(opts.user.id), name: opts.user.name, displayName: opts.user.displayName },
      pubKeyCredParams: opts.pubKeyCredParams,
      authenticatorSelection: opts.authenticatorSelection, timeout: opts.timeout,
      excludeCredentials: (opts.excludeCredentials || []).map(c => ({type:c.type, id:b64urlToBytes(c.id)}))
    };
    status.textContent = 'Waiting for passkey...';
    const cred = await navigator.credentials.create({publicKey});
    const body = JSON.stringify({id: bytesToB64url(cred.rawId), response:{attestationObject: bytesToB64url(cred.response.attestationObject), clientDataJSON: bytesToB64url(cred.response.clientDataJSON)}});
    const vr = await fetch('/auth/register/complete', {method:'POST', headers:{'Content-Type':'application/json'}, body});
    const result = await vr.json();
    if (result.ok) { status.className='status ok'; status.textContent='Passkey added.'; refreshPasskeys(); }
    else { status.className='status error'; status.textContent = result.error || 'Registration failed'; }
  } catch (e) { status.className='status error'; status.textContent = e.message || 'Registration failed'; }
};
const inviteBtn = document.getElementById('invite-btn');
if (inviteBtn) inviteBtn.onclick = async () => {
  const role = document.getElementById('invite-role').value;
  const r = await fetch('/auth/invite/create', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({role})});
  const j = await r.json();
  if (j.ok) {
    const fullUrl = window.location.origin + j.path;
    const out = document.getElementById('invite-out');
    out.innerHTML = '<div class="invite-box">' + fullUrl + '</div><div class="muted" style="margin-top:6px">Role: <strong>' + j.role + '</strong>. Valid for 7 days. One-time use.</div>';
  } else { status.className='status error'; status.textContent = j.error || 'Failed to create invite'; }
};
async function updateRole(sel, targetEmail) {
  const role = sel.value;
  const r = await fetch('/api/users/role', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({email: targetEmail, role})});
  if (!r.ok) { status.className='status error'; status.textContent = (await r.text()) || 'Update failed'; return; }
  status.className='status ok'; status.textContent = targetEmail + ' → ' + role;
}
async function deleteUser(targetEmail) {
  if (!confirm('Delete ' + targetEmail + '?\nThis removes their passkeys, sessions, and OAuth clients. This cannot be undone.')) return;
  const r = await fetch('/api/users/delete', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({email: targetEmail})});
  if (r.ok) { location.reload(); return; }
  let msg;
  try { msg = (await r.json()).error; } catch(e) { msg = await r.text(); }
  status.className='status error'; status.textContent = msg || 'Delete failed';
}
document.querySelectorAll('span[data-ts]').forEach(el => {
  const ts = parseInt(el.dataset.ts, 10);
  if (ts) el.textContent = new Date(ts * 1000).toLocaleString();
});
async function createClient(ev) {
  ev.preventDefault();
  const name = document.getElementById('client-name').value;
  const redirect_uri = document.getElementById('client-redirect').value;
  const r = await fetch('/api/oauth/clients', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name, redirect_uri})});
  if (!r.ok) { alert('Failed: ' + await r.text()); return false; }
  const d = await r.json();
  const out = document.getElementById('client-secret-output');
  out.innerHTML = '<div class="secret-box"><strong>Client ID:</strong><br>' + d.client_id +
    '<br><br><strong>Client Secret:</strong><br>' + d.client_secret +
    '</div><div class="warn">⚠ This is the only time the secret is shown. Copy it now.</div>' +
    '<p><a href="/account">Reload page</a> to see the new client in the table.</p>';
  return false;
}
async function revokeClient(id) {
  if (!confirm('Revoke client ' + id + '? Tokens issued to it stop working immediately.')) return;
  const r = await fetch('/api/oauth/clients/' + encodeURIComponent(id) + '/revoke', {method:'POST'});
  if (r.ok) location.reload(); else alert('Failed: ' + await r.text());
}
async function refreshPasswordStatus(){
  try {
    const r = await fetch('/auth/password/status');
    if (!r.ok) return;
    const j = await r.json();
    document.getElementById('pw-btn').textContent = j.set ? 'Change password' : 'Set password';
    document.getElementById('pw-help').textContent = j.set
      ? 'A password is set. You can sign in with it if you lose your passkey.'
      : 'Set a password as a fallback in case your passkey is lost.';
  } catch (e) {}
}
document.getElementById('pw-btn').onclick = async () => {
  const input = document.getElementById('pw-input');
  const pw = input.value;
  if (pw.length < 8) { status.className='status error'; status.textContent='Password must be at least 8 characters'; return; }
  const r = await fetch('/auth/password/set', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({password: pw})});
  const j = await r.json();
  if (j.ok) { status.className='status ok'; status.textContent='Password saved.'; input.value=''; refreshPasswordStatus(); }
  else { status.className='status error'; status.textContent = j.error || 'Failed to save password'; }
};
refreshPasskeys();
refreshPasswordStatus();
