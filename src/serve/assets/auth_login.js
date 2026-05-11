const btn = document.getElementById('login-btn');
const emailInput = document.getElementById('email');
const passwordInput = document.getElementById('password');
const toggle = document.getElementById('toggle-mode');
const status = document.getElementById('status');
let mode = 'passkey';
toggle.addEventListener('click', (e) => {
  e.preventDefault();
  if (mode === 'passkey') {
    mode = 'password';
    passwordInput.style.display = '';
    btn.textContent = 'Sign in with Password';
    toggle.textContent = 'Use passkey instead';
    passwordInput.focus();
  } else {
    mode = 'passkey';
    passwordInput.style.display = 'none';
    btn.textContent = 'Sign in with Passkey';
    toggle.textContent = 'Use password instead';
  }
  status.textContent = '';
});
async function doPasswordLogin(email) {
  status.textContent = 'Signing in...';
  const r = await fetch('/auth/password/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: passwordInput.value })
  });
  const j = await r.json();
  if (j.ok) {
    status.className = 'status ok';
    status.textContent = 'Authenticated!';
    window.location.href = '/';
  } else {
    throw new Error(j.error || 'Sign-in failed');
  }
}
btn.addEventListener('click', async () => {
  const email = emailInput.value.trim();
  if (!email || !email.includes('@')) {
    status.className = 'status error';
    status.textContent = 'Please enter a valid email address';
    return;
  }
  btn.disabled = true;
  status.className = 'status';
  try {
    if (mode === 'password') {
      await doPasswordLogin(email);
      return;
    }
    status.textContent = 'Requesting challenge...';
    const challengeRes = await fetch('/auth/login/challenge?email=' + encodeURIComponent(email));
    const opts = await challengeRes.json();
    if (!opts.allowCredentials || opts.allowCredentials.length === 0) {
      throw new Error('No passkey registered for this email on this server. Try "Use password instead" or ask an admin for an invite link.');
    }
    const publicKey = {
      challenge: b64urlToBytes(opts.challenge),
      rpId: opts.rpId,
      timeout: opts.timeout,
      userVerification: opts.userVerification,
      allowCredentials: (opts.allowCredentials || []).map(c => ({
        type: c.type,
        id: b64urlToBytes(c.id)
      }))
    };
    status.textContent = 'Waiting for passkey...';
    const cred = await navigator.credentials.get({ publicKey });
    status.textContent = 'Verifying...';
    const body = JSON.stringify({
      id: bytesToB64url(cred.rawId),
      response: {
        authenticatorData: bytesToB64url(cred.response.authenticatorData),
        clientDataJSON: bytesToB64url(cred.response.clientDataJSON),
        signature: bytesToB64url(cred.response.signature)
      }
    });
    const verifyRes = await fetch('/auth/login/complete', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: body
    });
    const result = await verifyRes.json();
    if (result.ok) {
      status.className = 'status ok';
      status.textContent = 'Authenticated!';
      window.location.href = '/';
    } else {
      status.className = 'status error';
      status.textContent = result.error || 'Authentication failed';
      btn.disabled = false;
    }
  } catch (e) {
    status.className = 'status error';
    status.textContent = e.message || 'Authentication failed';
    btn.disabled = false;
  }
});
