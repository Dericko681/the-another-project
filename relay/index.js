/**
 * LOCAL RELAY — OpenCode v2 spike
 *
 * Architecture discovery (confirmed by live probing):
 *
 *   opencode runs TWO processes:
 *   1. `opencode serve --service`  (started automatically by the desktop app /
 *      the first opencode invocation) — this is the REAL REST+SSE API server.
 *      Its URL and per-launch password live in:
 *        ~/.local/state/opencode/service.json
 *        { "url": "http://127.0.0.1:<port>", "password": "<random>", "pid": ... }
 *
 *   2. `opencode serve --stdio --port 0` — starts the WEB UI server (SPA).
 *      It only serves the React/Solid SPA and proxies to the service process.
 *      The `{"url": "..."}` it prints is the WEB UI port, NOT the API port.
 *
 *   The REST API lives at:  <service url>/api/...
 *   The SSE event stream:   <service url>/api/event
 *
 *   Auth: HTTP Basic  username="opencode"  password=<value from service.json>
 *
 * This relay:
 *   Session management
 *     GET    /sessions                    list sessions (?limit=&search=&archived=)
 *     POST   /sessions                    create a session {title?,agent?,model?}
 *     GET    /sessions/:id                one session
 *     PATCH  /sessions/:id                rename {title}
 *     DELETE /sessions/:id                delete a session
 *     GET    /sessions/:id/messages       full transcript, normalised for the UI
 *     POST   /sessions/:id/prompt         send a prompt into a session
 *     POST   /sessions/:id/command        run a slash-command {name,text?}
 *     POST   /sessions/:id/interrupt      stop a running execution
 *     POST   /sessions/:id/fork           fork a session
 *     POST   /sessions/:id/compact        compact the context
 *     POST   /sessions/:id/model          switch model {providerID,modelID,variant?}
 *     POST   /sessions/:id/agent          switch agent {agent}
 *   Metadata
 *     GET    /models                      available models (+ default)
 *     GET    /agents                      available agents
 *     GET    /commands                    available slash-commands
 *     GET    /active                      sessions currently running
 *   Streaming / compatibility
 *     POST   /prompt                      legacy: prompt the default session
 *     GET    /stream                      SSE fan-out of opencode's event stream
 *     GET    /health                      liveness check
 *
 * Run:
 *   node relay/index.js
 *   (No env vars needed — it reads service.json automatically)
 *
 * Override API URL manually (optional):
 *   OPENCODE_URL=http://127.0.0.1:49374 OPENCODE_PASSWORD=xxx node relay/index.js
 */

'use strict';

const fs      = require('fs');
const path    = require('path');
const express = require('express');
const fetch   = require('node-fetch');   // npm i node-fetch@2

const app = express();
app.use(express.json({ limit: '4mb' }));

// ── CORS — needed for Flutter web running in Chrome ───────────────────────────
// Without this, Chrome blocks cross-origin requests from localhost:8080 → :3000
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, PUT, DELETE, OPTIONS');
  // Echo back whatever headers the browser asks for in the preflight.
  // Flutter web sends "Cache-Control: no-cache" on the SSE request, which is a
  // non-simple header and therefore triggers a preflight — a fixed allow-list
  // that omitted it caused every /stream request to fail with a CORS error.
  res.setHeader(
    'Access-Control-Allow-Headers',
    req.get('Access-Control-Request-Headers') ||
      'Content-Type, Accept, Accept-Language, Content-Language, Cache-Control, Last-Event-ID'
  );
  // Let the browser reuse the preflight result for 10 minutes.
  res.setHeader('Access-Control-Max-Age', '600');
  if (req.method === 'OPTIONS') return res.sendStatus(204); // preflight
  next();
});

// ── Resolve opencode service credentials ─────────────────────────────────────

function readServiceJson() {
  const stateFile = path.join(
    process.env.XDG_STATE_HOME || path.join(process.env.HOME, '.local', 'state'),
    'opencode', 'service.json'
  );
  try {
    return JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  } catch (e) {
    return null;
  }
}

function resolveConfig() {
  // Explicit env vars override everything (useful for CI)
  if (process.env.OPENCODE_URL && process.env.OPENCODE_PASSWORD) {
    return { url: process.env.OPENCODE_URL.replace(/\/$/, ''), password: process.env.OPENCODE_PASSWORD };
  }

  const svc = readServiceJson();
  if (svc && svc.url && svc.password) {
    return { url: svc.url.replace(/\/$/, ''), password: svc.password };
  }

  // Fall back to env vars if only URL is set (no-password server)
  if (process.env.OPENCODE_URL) {
    return { url: process.env.OPENCODE_URL.replace(/\/$/, ''), password: process.env.OPENCODE_PASSWORD || '' };
  }

  return null;
}

const CONFIG = resolveConfig();
if (!CONFIG) {
  console.error('[relay] ERROR: cannot find opencode service credentials.');
  console.error('        Expected: ~/.local/state/opencode/service.json');
  console.error('        Or set:   OPENCODE_URL=...  OPENCODE_PASSWORD=...');
  process.exit(1);
}

const { url: OPENCODE_URL, password: OPENCODE_PASSWORD } = CONFIG;
const OPENCODE_USERNAME = process.env.OPENCODE_SERVER_USERNAME || 'opencode';

function authHeader() {
  if (!OPENCODE_PASSWORD) return {};
  const token = Buffer.from(`${OPENCODE_USERNAME}:${OPENCODE_PASSWORD}`).toString('base64');
  return { Authorization: `Basic ${token}` };
}

// ── State ─────────────────────────────────────────────────────────────────────

// Legacy default session used by POST /prompt (kept for backward compatibility).
let sessionId = null;
const sseClients = new Set();

// ── Helper: call opencode REST API ────────────────────────────────────────────

async function ocRaw(method, apiPath, body) {
  const opts = {
    method,
    headers: { 'Content-Type': 'application/json', 'Accept': 'application/json', ...authHeader() },
  };
  if (body !== undefined) opts.body = JSON.stringify(body);

  const res = await fetch(`${OPENCODE_URL}/api${apiPath}`, opts);

  // 204 No Content
  if (res.status === 204) return { status: 204, body: null };

  const text = await res.text();
  if (!res.ok) {
    const err = new Error(`opencode ${method} /api${apiPath} → ${res.status}: ${text}`);
    err.status = res.status;
    err.details = text;
    throw err;
  }

  try {
    return { status: res.status, body: JSON.parse(text) };
  } catch {
    return { status: res.status, body: text };
  }
}

/**
 * Like ocRaw, but unwraps opencode's `{ data: ... }` envelope.
 * Returns just the payload (the array for list endpoints).
 */
async function oc(method, apiPath, body) {
  const { body: parsed } = await ocRaw(method, apiPath, body);
  if (parsed && typeof parsed === 'object' && parsed.data !== undefined) return parsed.data;
  return parsed;
}

/** Express wrapper: forwards async errors with a sensible status code. */
const route = (fn) => (req, res) => {
  Promise.resolve(fn(req, res)).catch((err) => {
    console.error(`[relay] ${req.method} ${req.originalUrl} error:`, err.message);
    if (res.headersSent) return;
    // Pass client errors (404 unknown session, 400 bad payload) straight
    // through; anything else is an upstream relay failure.
    const status = err.status && err.status < 500 ? err.status : 502;
    res.status(status).json({ error: err.message, status: err.status ?? null });
  });
};

const qs = (params) => {
  const p = Object.entries(params).filter(([, v]) => v !== undefined && v !== null && v !== '');
  if (p.length === 0) return '';
  return '?' + p.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
};

// ── Normalisers: opencode shapes → shapes that are pleasant in Flutter ───────

function normaliseSession(s, active = {}) {
  if (!s || !s.id) return null;
  return {
    id: s.id,
    slug: s.slug ?? null,
    // Untitled sessions stay empty so the app can show "New session" and let
    // opencode auto-name the session on the first prompt.
    title: s.title || '',
    projectID: s.projectID ?? null,
    directory: s.location?.directory ?? s.project?.directory ?? null,
    agent: s.agent ?? null,
    model: s.model
      ? { id: s.model.id, providerID: s.model.providerID, variant: s.model.variant ?? null }
      : null,
    cost: s.cost ?? 0,
    tokens: s.tokens ?? null,
    created: s.time?.created ?? null,
    updated: s.time?.updated ?? null,
    running: !!active[s.id],
  };
}

/**
 * opencode transcripts are a list of typed messages:
 *   user            { text }
 *   assistant       { content: [ {type:'text'|'reasoning'|'tool'|...} ] }
 *   idle / model-switched / agent-switched / compaction   (collection changes)
 *
 * Flatten to { id, role, text, reasoning, tools, ... } so the UI can render
 * without knowing about parts.
 */
function normaliseMessage(m) {
  if (!m || !m.id) return null;
  const base = {
    id: m.id,
    createdAt: m.time?.created ?? null,
    kind: m.type ?? 'unknown',
  };

  if (m.type === 'user') {
    return {
      ...base,
      role: 'user',
      text: m.text ?? m.payload?.text ?? '',
      reasoning: '',
      tools: [],
    };
  }

  if (m.type === 'assistant') {
    const parts = Array.isArray(m.content) ? m.content : [];
    const pick = (type) =>
      parts.filter((p) => p && p.type === type && typeof p.text === 'string')
        .map((p) => p.text)
        .join('');

    const tools = parts
      .filter((p) => p && p.type === 'tool')
      .map((p) => ({
        id: p.id ?? null,
        name: p.name ?? 'tool',
        status: p.state?.status ?? 'unknown',
        title: p.state?.title ?? null,
        input: p.state?.input ?? null,
        output: p.state?.output ?? p.state?.content ?? null,
        error: p.state?.error ?? null,
      }));

    return {
      ...base,
      role: 'assistant',
      text: pick('text'),
      reasoning: pick('reasoning'),
      tools,
      agent: m.agent ?? null,
      model: m.model ?? null,
      cost: m.cost ?? 0,
      tokens: m.tokens ?? null,
      finish: m.finish ?? null,
    };
  }

  // idle / model-switched / agent-switched / compaction → transcript markers
  const labels = {
    'model-switched': (v) => `model → ${v?.model?.id ?? 'unknown'}`,
    'agent-switched': (v) => `agent → ${v?.agent ?? 'unknown'}`,
    compaction: () => 'context compacted',
    idle: () => 'idle',
  };
  const label = labels[m.type]?.(m.payload ?? m) ?? m.type ?? 'event';

  return {
    ...base,
    role: 'system',
    text: label,
    reasoning: '',
    tools: [],
  };
}

async function activeSessions() {
  try {
    const data = await oc('GET', '/session/active');
    return data && typeof data === 'object' ? data : {};
  } catch {
    return {};
  }
}

// ── Fan-out: subscribe to /api/event and forward to Flutter clients ───────────

async function subscribeToOpencode() {
  console.log(`[relay] subscribing to ${OPENCODE_URL}/api/event …`);
  try {
    const res = await fetch(`${OPENCODE_URL}/api/event`, {
      headers: { Accept: 'text/event-stream', ...authHeader() },
    });

    if (!res.ok) throw new Error(`/api/event returned ${res.status}`);

    res.body.on('data', (chunk) => {
      const text = chunk.toString();
      for (const client of sseClients) {
        client.write(text);
      }
    });

    res.body.on('end', () => {
      console.warn('[relay] opencode event stream closed — reconnecting in 2 s');
      setTimeout(subscribeToOpencode, 2000);
    });

    res.body.on('error', (err) => {
      console.error('[relay] event stream error:', err.message);
      setTimeout(subscribeToOpencode, 2000);
    });
  } catch (err) {
    console.error('[relay] failed to connect to event stream:', err.message);
    console.error('        Will retry in 3 s …');
    setTimeout(subscribeToOpencode, 3000);
  }
}

// ── Ensure a session exists (legacy /prompt) ─────────────────────────────────

async function ensureSession() {
  if (sessionId) return sessionId;
  const session = await oc('POST', '/session', { title: 'flutter-spike' });
  sessionId = session.id;
  console.log(`[relay] created session ${sessionId}`);
  return sessionId;
}

// ── Session routes ───────────────────────────────────────────────────────────

/** GET /sessions?limit=50&search=&archived= — newest first. */
app.get('/sessions', route(async (req, res) => {
  const [data, active] = await Promise.all([
    oc('GET', `/session${qs({
      limit: req.query.limit ? parseInt(req.query.limit, 10) : 100,
      order: 'desc',
      search: req.query.search,
      archived: req.query.archived,
    })}`),
    activeSessions(),
  ]);

  const sessions = (Array.isArray(data) ? data : [])
    .map((s) => normaliseSession(s, active))
    .filter(Boolean);

  res.json({ sessions });
}));

/** POST /sessions {title?, agent?, model?, directory?} — create and select. */
app.post('/sessions', route(async (req, res) => {
  const { title, agent, model, directory } = req.body || {};
  const body = {};
  if (title) body.title = title;
  if (agent) body.agent = agent;
  if (model) {
    // Accept {id, providerID} as well as the more explicit {modelID, providerID};
    // opencode's schema expects `id`.
    body.model = {
      id: model.id ?? model.modelID,
      providerID: model.providerID,
      ...(model.variant ? { variant: model.variant } : {}),
    };
  }
  if (directory) body.location = { directory };

  const created = await oc('POST', '/session', body);
  const active = await activeSessions();
  res.json({ session: normaliseSession(created, active) });
}));

/** GET /sessions/:id */
app.get('/sessions/:id', route(async (req, res) => {
  const [data, active] = await Promise.all([
    oc('GET', `/session/${encodeURIComponent(req.params.id)}`),
    activeSessions(),
  ]);
  res.json({ session: normaliseSession(data, active) });
}));

/** PATCH /sessions/:id {title} — rename. */
app.patch('/sessions/:id', route(async (req, res) => {
  const { title } = req.body || {};
  if (!title) return res.status(400).json({ error: 'title field required' });
  await oc('PATCH', `/session/${encodeURIComponent(req.params.id)}`, { title });
  res.json({ ok: true, id: req.params.id, title });
}));

/** DELETE /sessions/:id */
app.delete('/sessions/:id', route(async (req, res) => {
  await oc('DELETE', `/session/${encodeURIComponent(req.params.id)}`);
  if (sessionId === req.params.id) sessionId = null;
  res.json({ ok: true, id: req.params.id });
}));

/** GET /sessions/:id/messages?limit= — normalised transcript, oldest first. */
app.get('/sessions/:id/messages', route(async (req, res) => {
  const limit = req.query.limit ? parseInt(req.query.limit, 10) : 200;

  // opencode returns newest-first and supports order=asc. We ask for the newest
  // `limit` messages and reverse them, which keeps the tail of a long
  // conversation (the part the UI shows) instead of its head.
  const { body } = await ocRaw('GET', `/session/${encodeURIComponent(req.params.id)}/message${qs({
    limit,
    order: 'desc',
  })}`);

  const list = Array.isArray(body?.data) ? body.data : [];
  const messages = list.map(normaliseMessage).filter(Boolean).reverse();

  res.json({ messages, cursor: body?.cursor ?? null });
}));

/**
 * POST /sessions/:id/prompt
 * Body: { prompt | text, providerID?, modelID?, variant?, agent?, delivery? }
 *
 * opencode's prompt endpoint accepts only {text, files, agents, skills, metadata,
 * delivery, resume} — a model is NOT part of the prompt payload. Passing
 * providerID/modelID is therefore implemented as an explicit model switch first.
 * `agent` likewise switches the session agent before prompting.
 */
app.post('/sessions/:id/prompt', route(async (req, res) => {
  const sid = req.params.id;
  const body = req.body || {};
  const text = body.prompt ?? body.text;

  if (!text) return res.status(400).json({ error: 'prompt (or text) field required' });

  if (body.providerID && body.modelID) {
    await oc('POST', `/session/${encodeURIComponent(sid)}/model`, {
      model: {
        id: body.modelID,
        providerID: body.providerID,
        ...(body.variant ? { variant: body.variant } : {}),
      },
    });
  }

  if (body.agent) {
    await oc('POST', `/session/${encodeURIComponent(sid)}/agent`, { agent: body.agent });
  }

  const payload = { text };
  if (body.delivery === 'queue' || body.delivery === 'steer') payload.delivery = body.delivery;

  const message = await oc('POST', `/session/${encodeURIComponent(sid)}/prompt`, payload);
  res.json({ status: 'dispatched', sessionId: sid, messageId: message?.id ?? null });
}));

/** POST /sessions/:id/command {name, text?} — run a slash-command. */
app.post('/sessions/:id/command', route(async (req, res) => {
  const { name, text } = req.body || {};
  if (!name) return res.status(400).json({ error: 'name field required' });

  await oc('POST', `/session/${encodeURIComponent(req.params.id)}/command`, {
    name,
    ...(text ? { text } : {}),
  });
  res.json({ status: 'dispatched', sessionId: req.params.id, command: name });
}));

/** POST /sessions/:id/interrupt — stop a running execution. */
app.post('/sessions/:id/interrupt', route(async (req, res) => {
  const result = await oc('POST', `/session/${encodeURIComponent(req.params.id)}/interrupt`);
  res.json({ sessionId: req.params.id, interrupted: result?.interrupted ?? true });
}));

/** POST /sessions/:id/fork — branch the transcript. */
app.post('/sessions/:id/fork', route(async (req, res) => {
  const { before } = req.body || {};
  const created = await oc('POST', `/session/${encodeURIComponent(req.params.id)}/fork`, {
    ...(before ? { before } : {}),
  });
  const active = await activeSessions();
  res.json({ session: normaliseSession(created, active) });
}));

/** POST /sessions/:id/compact — summarise the context. */
app.post('/sessions/:id/compact', route(async (req, res) => {
  const result = await oc('POST', `/session/${encodeURIComponent(req.params.id)}/compact`, {});
  res.json({ status: 'compacting', sessionId: req.params.id, messageId: result?.id ?? null });
}));

/** POST /sessions/:id/model {providerID, modelID, variant?} */
app.post('/sessions/:id/model', route(async (req, res) => {
  const { providerID, modelID, variant } = req.body || {};
  if (!providerID || !modelID) {
    return res.status(400).json({ error: 'providerID and modelID required' });
  }
  await oc('POST', `/session/${encodeURIComponent(req.params.id)}/model`, {
    model: { id: modelID, providerID, variant: variant ?? 'default' },
  });
  res.json({ ok: true, sessionId: req.params.id, model: { providerID, modelID, variant: variant ?? null } });
}));

/** POST /sessions/:id/agent {agent} */
app.post('/sessions/:id/agent', route(async (req, res) => {
  const { agent } = req.body || {};
  if (!agent) return res.status(400).json({ error: 'agent field required' });
  await oc('POST', `/session/${encodeURIComponent(req.params.id)}/agent`, { agent });
  res.json({ ok: true, sessionId: req.params.id, agent });
}));

// ── Metadata routes ──────────────────────────────────────────────────────────

/** GET /models — flattened model list + the current default. */
app.get('/models', route(async (_req, res) => {
  const [models, def] = await Promise.all([
    oc('GET', '/model'),          // {location, data:[...]} → unwrapped to array
    oc('GET', '/model/default').catch(() => null),
  ]);

  const list = (Array.isArray(models) ? models : []).map((m) => ({
    id: m.modelID ?? m.id,
    providerID: m.providerID,
    name: m.name ?? m.id,
    family: m.family ?? null,
    contextLimit: m.limit?.context ?? null,
    outputLimit: m.limit?.output ?? null,
    input: m.capabilities?.input ?? null,
  }));

  res.json({
    models: list,
    default: def
      ? { id: def.modelID ?? def.id, providerID: def.providerID, name: def.name ?? def.id }
      : null,
  });
}));

/** GET /agents — id + name + description only (the system prompt is huge). */
app.get('/agents', route(async (_req, res) => {
  const data = await oc('GET', '/agent');
  const list = (Array.isArray(data) ? data : []).map((a) => ({
    id: a.id,
    name: a.name ?? a.id,
    description: a.description ?? (a.system ? a.system.split('\n')[0].slice(0, 160) : null),
    mode: a.mode ?? null,
  }));
  res.json({ agents: list });
}));

/** GET /commands — slash-commands available in this workspace. */
app.get('/commands', route(async (_req, res) => {
  const data = await oc('GET', '/command');
  const list = (Array.isArray(data) ? data : []).map((c) => ({
    name: c.name,
    description: c.description ?? null,
    agent: c.agent ?? null,
  }));
  res.json({ commands: list });
}));

/** GET /active — { sessionId: {type} } for sessions with a running execution. */
app.get('/active', route(async (_req, res) => {
  res.json({ active: await activeSessions() });
}));

// ── Legacy / compatibility routes ────────────────────────────────────────────

/**
 * POST /prompt
 * Body: { "prompt": "...", "providerID": "...", "modelID": "..." }
 * Uses (or creates) the relay's default session. Kept for backward compatibility
 * with the original spike; the Flutter app now uses POST /sessions/:id/prompt.
 */
app.post('/prompt', route(async (req, res) => {
  const { prompt, providerID, modelID } = req.body || {};
  if (!prompt) return res.status(400).json({ error: 'prompt field required' });

  const sid = await ensureSession();

  if (providerID && modelID) {
    await oc('POST', `/session/${encodeURIComponent(sid)}/model`, {
      model: { id: modelID, providerID, variant: 'default' },
    });
  }

  await oc('POST', `/session/${encodeURIComponent(sid)}/prompt`, { text: prompt });
  res.json({ status: 'dispatched', sessionId: sid });
}));

/**
 * GET /stream
 *
 * SSE endpoint. Flutter connects here and receives every event
 * forwarded from the opencode /api/event stream.
 *
 * Notable event types:
 *   server.connected              — first event after subscribe
 *   session.created               — a session appeared
 *   session.renamed               — title changed
 *   session.deleted               — session removed
 *   session.model.selected        — model switched
 *   session.agent.selected        — agent switched
 *   session.inbox.enqueued        — prompt accepted into queue
 *   session.execution.started     — work begins
 *   session.text.delta            — streaming token (data.delta)
 *   session.text.ended            — full text (data.text)
 *   session.reasoning.delta       — reasoning stream (data.delta)
 *   session.execution.succeeded   — done
 *   session.execution.failed      — error
 *   session.execution.interrupted — stopped by interrupt
 *
 * Every session-scoped event carries data.sessionID.
 */
app.get('/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  const heartbeat = setInterval(() => res.write(': ping\n\n'), 15_000);

  sseClients.add(res);
  console.log(`[relay] Flutter client connected (${sseClients.size} total)`);

  req.on('close', () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
    console.log(`[relay] Flutter client disconnected (${sseClients.size} remaining)`);
  });
});

/**
 * GET /health
 * Returns relay status + proxied opencode health.
 */
app.get('/health', route(async (_req, res) => {
  const [sessions, info] = await Promise.all([
    oc('GET', '/session'),
    oc('GET', '/info').catch(() => null),
  ]);
  res.json({
    relay: 'ok',
    opencode_url: OPENCODE_URL,
    opencode_version: info?.version ?? null,
    session_count: Array.isArray(sessions) ? sessions.length : '?',
  });
}));

// ── Boot ──────────────────────────────────────────────────────────────────────

const RELAY_PORT = parseInt(process.env.RELAY_PORT || '3000', 10);

app.listen(RELAY_PORT, async () => {
  console.log(`[relay] listening on http://127.0.0.1:${RELAY_PORT}`);
  console.log(`[relay] forwarding to opencode at ${OPENCODE_URL}`);
  console.log('[relay] session API:');
  console.log('          GET    /sessions            list sessions');
  console.log('          POST   /sessions            create session');
  console.log('          PATCH  /sessions/:id        rename');
  console.log('          DELETE /sessions/:id        delete');
  console.log('          GET    /sessions/:id/messages');
  console.log('          POST   /sessions/:id/prompt');
  console.log('          POST   /sessions/:id/interrupt');
  console.log('          POST   /sessions/:id/fork');
  console.log('          POST   /sessions/:id/compact');
  console.log('          POST   /sessions/:id/model');
  console.log('          POST   /sessions/:id/agent');
  console.log('          GET    /models /agents /commands /active');
  await subscribeToOpencode();
});
