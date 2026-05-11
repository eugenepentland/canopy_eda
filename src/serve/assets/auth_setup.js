const btn = document.getElementById('register-btn');
const emailInput = document.getElementById('email');
const status = document.getElementById('status');
btn.addEventListener('click', async () => {
  const email = emailInput.value.trim();
  if (!email || !email.includes('@')) {
    status.className = 'status error';
    status.textContent = 'Please enter a valid email address';
    return;
  }
  btn.disabled = true;
  status.className = 'status';
  status.textContent = 'Requesting challenge...';
  try {
    const challengeRes = await fetch('/auth/register/challenge?email=' + encodeURIComponent(email));
    const opts = await challengeRes.json();
    const publicKey = {
      challenge: b64urlToBytes(opts.challenge),
      rp: opts.rp,
      user: {
        id: b64urlToBytes(opts.user.id),
        name: opts.user.name,
        displayName: opts.user.displayName
      },
      pubKeyCredParams: opts.pubKeyCredParams,
      authenticatorSelection: opts.authenticatorSelection,
      timeout: opts.timeout
    };
    status.textContent = 'Waiting for passkey...';
    const cred = await navigator.credentials.create({ publicKey });
    status.textContent = 'Registering...';
    const body = JSON.stringify({
      id: bytesToB64url(cred.rawId),
      email: email,
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
      status.textContent = 'Passkey registered!';
      window.location.href = '/';
    } else {
      status.className = 'status error';
      status.textContent = result.error || 'Registration failed';
      btn.disabled = false;
    }
  } catch (e) {
    status.className = 'status error';
    status.textContent = e.message || 'Registration failed';
    btn.disabled = false;
  }
});
