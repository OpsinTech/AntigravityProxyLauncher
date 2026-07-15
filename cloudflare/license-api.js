/**
 * AntigravityProxyLauncher - License API Worker
 * 
 * Endpoints:
 *   POST /activate   - Activate a license key on a device
 *   POST /verify     - Verify a license is still valid
 *   POST /renew      - Renew/upgrade a license (admin or payment webhook)
 *   GET  /status     - Get license status without consuming activation
 * 
 * Storage: Cloudflare Workers KV
 *   Key format: "license:{licenseKey}"
 *   Value: JSON { plan, expiresAt, machineId, activatedAt, createdAt }
 */

// ---- CORS headers ----
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-License-Key',
  'Access-Control-Max-Age': '86400',
};

// ---- HMAC secret for admin operations ----
// Set via Cloudflare Workers secrets: wrangler secret put LICENSE_ADMIN_SECRET
const ADMIN_SECRET = LICENSE_ADMIN_SECRET || 'change-me-in-production';

// ---- Rate limiting (simple per-IP) ----
async function checkRateLimit(request, env) {
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  const key = `ratelimit:${ip}`;
  const now = Math.floor(Date.now() / 1000);
  
  const record = await env.LICENSE_STORE.get(key, { type: 'json' }) || { count: 0, reset: now + 3600 };
  if (now > record.reset) {
    record.count = 1;
    record.reset = now + 3600;
  } else {
    record.count++;
  }
  
  await env.LICENSE_STORE.put(key, JSON.stringify(record), { expirationTtl: 3600 });
  return record.count <= 100; // 100 req/hour per IP
}

// ---- Helpers ----
function json(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function generateKey() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const segments = [];
  for (let s = 0; s < 4; s++) {
    let seg = '';
    for (let i = 0; i < 4; i++) seg += chars[Math.floor(Math.random() * chars.length)];
    segments.push(seg);
  }
  return segments.join('-');
}

function hashMachineId(machineId) {
  // Simple SHA-256 hash for storage (not security-critical, just privacy)
  return machineId; // In production, use crypto.subtle.digest
}

// ---- Main handler ----
export default {
  async fetch(request, env, ctx) {
    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    // Rate limit
    if (!(await checkRateLimit(request, env))) {
      return json({ error: 'rate_limited', message: 'Too many requests' }, 429);
    }

    const url = new URL(request.url);
    const path = url.pathname;

    try {
      switch (path) {
        case '/activate':
          return await handleActivate(request, env);
        case '/verify':
          return await handleVerify(request, env);
        case '/renew':
          return await handleRenew(request, env);
        case '/status':
          return await handleStatus(request, env);
        default:
          return json({ error: 'not_found' }, 404);
      }
    } catch (err) {
      console.error('License API error:', err);
      return json({ error: 'internal_error', message: err.message }, 500);
    }
  },
};

// ---- POST /activate ----
async function handleActivate(request, env) {
  const body = await request.json().catch(() => ({}));
  const { licenseKey, machineId } = body;

  if (!licenseKey || !machineId) {
    return json({ error: 'missing_fields', message: 'licenseKey and machineId are required' }, 400);
  }

  const key = `license:${licenseKey}`;
  const record = await env.LICENSE_STORE.get(key, { type: 'json' });

  if (!record) {
    return json({ valid: false, reason: 'invalid_key', message: 'License key not found' }, 404);
  }

  // Check if already activated on another machine
  if (record.machineId && record.machineId !== machineId) {
    return json({ 
      valid: false, 
      reason: 'already_activated', 
      message: 'This license is already activated on another device' 
    }, 409);
  }

  // Check expiration
  const now = new Date();
  const expiresAt = new Date(record.expiresAt);
  if (now > expiresAt) {
    return json({ valid: false, reason: 'expired', message: 'License has expired', expiresAt: record.expiresAt });
  }

  // Activate: bind machineId if not already set
  if (!record.machineId) {
    record.machineId = machineId;
    record.activatedAt = now.toISOString();
    await env.LICENSE_STORE.put(key, JSON.stringify(record));
  }

  return json({
    valid: true,
    plan: record.plan || 'pro',
    expiresAt: record.expiresAt,
    activatedAt: record.activatedAt,
  });
}

// ---- POST /verify ----
async function handleVerify(request, env) {
  const body = await request.json().catch(() => ({}));
  const { licenseKey, machineId } = body;

  if (!licenseKey || !machineId) {
    return json({ error: 'missing_fields' }, 400);
  }

  const key = `license:${licenseKey}`;
  const record = await env.LICENSE_STORE.get(key, { type: 'json' });

  if (!record) {
    return json({ valid: false, reason: 'invalid_key' });
  }

  if (record.machineId && record.machineId !== machineId) {
    return json({ valid: false, reason: 'machine_mismatch' });
  }

  const now = new Date();
  const expiresAt = new Date(record.expiresAt);
  if (now > expiresAt) {
    return json({ valid: false, reason: 'expired', expiresAt: record.expiresAt });
  }

  return json({
    valid: true,
    plan: record.plan || 'pro',
    expiresAt: record.expiresAt,
    daysRemaining: Math.max(0, Math.ceil((expiresAt - now) / (1000 * 60 * 60 * 24))),
  });
}

// ---- POST /renew ----
async function handleRenew(request, env) {
  const body = await request.json().catch(() => ({}));
  const { licenseKey, adminSecret, newExpiresAt, plan } = body;

  // Require admin secret for renewal
  if (adminSecret !== ADMIN_SECRET) {
    return json({ error: 'unauthorized' }, 403);
  }

  if (!licenseKey) {
    return json({ error: 'missing_fields' }, 400);
  }

  const key = `license:${licenseKey}`;
  const record = await env.LICENSE_STORE.get(key, { type: 'json' });

  if (!record) {
    return json({ error: 'not_found' }, 404);
  }

  if (newExpiresAt) record.expiresAt = newExpiresAt;
  if (plan) record.plan = plan;

  await env.LICENSE_STORE.put(key, JSON.stringify(record));

  return json({ success: true, licenseKey, expiresAt: record.expiresAt, plan: record.plan });
}

// ---- GET /status ----
async function handleStatus(request, env) {
  const licenseKey = request.headers.get('X-License-Key') || new URL(request.url).searchParams.get('key');

  if (!licenseKey) {
    return json({ error: 'missing_key' }, 400);
  }

  const key = `license:${licenseKey}`;
  const record = await env.LICENSE_STORE.get(key, { type: 'json' });

  if (!record) {
    return json({ valid: false, reason: 'invalid_key' });
  }

  const now = new Date();
  const expiresAt = new Date(record.expiresAt);

  return json({
    valid: now <= expiresAt,
    plan: record.plan || 'pro',
    expiresAt: record.expiresAt,
    daysRemaining: Math.max(0, Math.ceil((expiresAt - now) / (1000 * 60 * 60 * 24))),
    activated: !!record.machineId,
  });
}
