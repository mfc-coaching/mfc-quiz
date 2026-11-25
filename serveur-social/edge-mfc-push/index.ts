// MFC Coaching — envoi des notifications (Supabase Edge Function « mfc-push »)
// Appelée chaque minute par pg_cron quand des notifications sont dues, et par l'appli (?key) pour la clé publique.
// Pas de JWT exigé : la fonction n'accepte aucune donnée, elle envoie seulement ce qui est dû dans la file.
// Les clés VAPID sont créées automatiquement au premier appel et gardées dans la base.
import postgres from 'npm:postgres@3.4.5';

const sql = postgres(Deno.env.get('SUPABASE_DB_URL'), { prepare: false, max: 2 });
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Content-Type': 'application/json' };

function b64u(buf) { const a = new Uint8Array(buf); let s = ''; for (let i = 0; i < a.length; i++) s += String.fromCharCode(a[i]); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
function ub64(s) { s = s.replace(/-/g, '+').replace(/_/g, '/'); s += '='.repeat((4 - s.length % 4) % 4); const b = atob(s); const a = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) a[i] = b.charCodeAt(i); return a; }
function cat(...parts) { const n = parts.reduce((t, p) => t + p.length, 0); const o = new Uint8Array(n); let i = 0; for (const p of parts) { o.set(p, i); i += p.length; } return o; }
const te = new TextEncoder();

// --- Clés VAPID (créées une seule fois) ---
let KEYS = null;
async function keys() {
  if (KEYS) return KEYS;
  let r = await sql`select pub, priv from public.mfc_push_keys where id = 1`;
  if (!r.length) {
    const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pub = b64u(await crypto.subtle.exportKey('raw', kp.publicKey));
    const priv = await crypto.subtle.exportKey('jwk', kp.privateKey);
    await sql`insert into public.mfc_push_keys (id, pub, priv) values (1, ${pub}, ${sql.json(priv)}) on conflict (id) do nothing`;
    r = await sql`select pub, priv from public.mfc_push_keys where id = 1`;
  }
  const priv = typeof r[0].priv === 'string' ? JSON.parse(r[0].priv) : r[0].priv;
  KEYS = { pub: r[0].pub, key: await crypto.subtle.importKey('jwk', priv, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']) };
  return KEYS;
}

// --- En-tête VAPID (JWT ES256) ---
async function vapid(endpoint, k) {
  const enc = (o) => b64u(te.encode(JSON.stringify(o)));
  const unsigned = enc({ typ: 'JWT', alg: 'ES256' }) + '.' + enc({ aud: new URL(endpoint).origin, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: 'mailto:contact@mathisfelicite.fr' });
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, k.key, te.encode(unsigned));
  return 'vapid t=' + unsigned + '.' + b64u(sig) + ', k=' + k.pub;
}

// --- Chiffrement du message (RFC 8291, aes128gcm) ---
async function hkdf(salt, ikm, info, len) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, len * 8));
}
async function encrypt(p256dh, authSecret, payload) {
  const uaPub = ub64(p256dh), auth = ub64(authSecret);
  const as = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', as.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, as.privateKey, 256));
  const ikm = await hkdf(auth, shared, cat(te.encode('WebPush: info\0'), uaPub, asPub), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 12);
  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, cat(payload, new Uint8Array([2]))));
  const head = new Uint8Array(86);
  head.set(salt, 0); new DataView(head.buffer).setUint32(16, 4096); head[20] = 65; head.set(asPub, 21);
  return cat(head, ct);
}
async function send(sub, msg, k) {
  const body = await encrypt(sub.p256dh, sub.auth, te.encode(JSON.stringify(msg)));
  return fetch(sub.endpoint, { method: 'POST', headers: { Authorization: await vapid(sub.endpoint, k), 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '43200', Urgency: 'high' }, body });
}


Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  try {
    const k = await keys();
    const url = new URL(req.url);
    if (url.searchParams.has('key')) return new Response(JSON.stringify({ pub: k.pub }), { headers: CORS });
    const due = await sql`
      update public.mfc_push_queue q set sent = true, sent_at = now()
       where q.id in (select id from public.mfc_push_queue where not sent and send_at <= now() order by send_at limit 200 for update skip locked)
      returning q.id, q.account_id, q.send_at, q.title, q.body, q.url, q.tag`;
    let ok = 0, dead = 0;
    const errors = [];
    for (const it of due) {
      if (Date.now() - new Date(it.send_at).getTime() > 3 * 3600 * 1000) continue; // trop ancien : on ignore
      const subs = await sql`select endpoint, p256dh, auth from public.mfc_push_subs where account_id = ${it.account_id}`;
      for (const s of subs) {
        try {
          const r = await send(s, { title: it.title, body: it.body || '', url: it.url || './', tag: it.tag || 'mfc' }, k);
          if (r.status === 404 || r.status === 410) { await sql`delete from public.mfc_push_subs where endpoint = ${s.endpoint}`; dead++; }
          else if (r.ok) ok++;
          else errors.push(r.status + ' ' + (await r.text()).slice(0, 200));
        } catch (e) { errors.push(String(e && e.message || e).slice(0, 200)); }
      }
    }
    if (errors.length) console.log('push errors', JSON.stringify(errors));
    return new Response(JSON.stringify({ due: due.length, sent: ok, removed: dead, errors }), { headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e && e.message || e) }), { status: 500, headers: CORS });
  }
});
