const status = document.getElementById('status');
function fmtDate(ts) {
  if (!ts) return 'Unknown';
  const d = new Date(ts * 1000);
  return d.toLocaleString();
}
async function refresh() {
  const r = await fetch('/auth/credentials/list');
  if (!r.ok) { window.location.href = '/auth/login'; return; }
  const data = await r.json();
  document.getElementById('user-email').textContent = data.email;
  const list = document.getElementById('passkey-list');
  list.innerHTML = '';
  for (const c of data.credentials) {
    const row = document.createElement('div');
    row.className = 'row';
    const meta = document.createElement('div');
    const added = document.createElement('div');
    added.className = 'meta';
    added.textContent = 'Added ' + fmtDate(c.created_at);
    const title = document.createElement('div');
    title.textContent = 'Passkey';
    meta.appendChild(title);
    meta.appendChild(added);
    const btn = document.createElement('button');
    btn.textContent = 'Delete';
    btn.onclick = async () => {
      if (data.credentials.length <= 1) {
        status.className = 'status error';
        status.textContent = 'Cannot delete your only passkey. Add another first.';
        return;
      }
      if (!confirm('Delete this passkey?')) return;
      const rr = await fetch('/auth/credentials/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: c.id })
      });
      const j = await rr.json();
      if (j.ok) { refresh(); } else {
        status.className = 'status error';
        status.textContent = j.error || 'Delete failed';
      }
    };
    row.appendChild(meta);
    row.appendChild(btn);
    list.appendChild(row);
  }
}
document.getElementById('logout-btn').onclick = async () => {
  await fetch('/auth/logout', { method: 'POST' });
  window.location.href = '/auth/login';
};
async function refreshPasswordStatus() {
  try {
    const r = await fetch('/auth/password/status');
    if (!r.ok) return;
    const j = await r.json();
    document.getElementById('pw-btn').textContent = j.set ? 'Change password' : 'Set password';
    document.getElementById('pw-help').textContent = j.set
      ? 'A password is set. You can sign in with it if you lose your passkey.'
      : 'Set a password as a fallback in case your passkey is lost.';
  } catch (e) { /* noop */ }
}
document.getElementById('pw-btn').onclick = async () => {
  const pw = document.getElementById('pw-input').value;
  if (pw.length < 8) {
    status.className = 'status error';
    status.textContent = 'Password must be at least 8 characters';
    return;
  }
  const r = await fetch('/auth/password/set', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: pw })
  });
  const j = await r.json();
  if (j.ok) {
    status.className = 'status ok';
    status.textContent = 'Password saved.';
    document.getElementById('pw-input').value = '';
    refreshPasswordStatus();
  } else {
    status.className = 'status error';
    status.textContent = j.error || 'Failed to save password';
  }
};
document.getElementById('add-btn').onclick = async () => {
  status.className = 'status';
  status.textContent = 'Requesting challenge...';
  try {
    const challengeRes = await fetch('/auth/register/challenge');
    const opts = await challengeRes.json();
    if (!challengeRes.ok) throw new Error(opts.error || 'Challenge failed');
    const publicKey = {
      challenge: b64urlToBytes(opts.challenge),
      rp: opts.rp,
      user: { id: b64urlToBytes(opts.user.id), name: opts.user.name, displayName: opts.user.displayName },
      pubKeyCredParams: opts.pubKeyCredParams,
      authenticatorSelection: opts.authenticatorSelection,
      timeout: opts.timeout,
      excludeCredentials: (opts.excludeCredentials || []).map(c => ({ type: c.type, id: b64urlToBytes(c.id) }))
    };
    status.textContent = 'Waiting for passkey...';
    const cred = await navigator.credentials.create({ publicKey });
    status.textContent = 'Registering...';
    const body = JSON.stringify({
      id: bytesToB64url(cred.rawId),
      response: {
        attestationObject: bytesToB64url(cred.response.attestationObject),
        clientDataJSON: bytesToB64url(cred.response.clientDataJSON)
      }
    });
    const verifyRes = await fetch('/auth/register/complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: body
    });
    const result = await verifyRes.json();
    if (result.ok) {
      status.className = 'status ok';
      status.textContent = 'Passkey added.';
      refresh();
    } else {
      status.className = 'status error';
      status.textContent = result.error || 'Registration failed';
    }
  } catch (e) {
    status.className = 'status error';
    status.textContent = e.message || 'Registration failed';
  }
};
document.getElementById('invite-btn').onclick = async () => {
  const r = await fetch('/auth/invite/create', { method: 'POST' });
  const j = await r.json();
  if (j.ok) {
    const fullUrl = window.location.origin + j.path;
    const out = document.getElementById('invite-out');
    out.innerHTML = '';
    const box = document.createElement('div');
    box.className = 'invite-box';
    box.textContent = fullUrl;
    const note = document.createElement('div');
    note.style.color = '#8b949e';
    note.style.fontSize = '0.8rem';
    note.style.marginTop = '6px';
    note.textContent = 'Valid for 7 days. One-time use.';
    out.appendChild(box);
    out.appendChild(note);
  } else {
    status.className = 'status error';
    status.textContent = j.error || 'Failed to create invite';
  }
};
refresh();
refreshPasswordStatus();
