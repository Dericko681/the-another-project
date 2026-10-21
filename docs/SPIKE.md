# OpenCode v2 → Node Relay → Flutter SSE — Spike Notes

> **Status: confirmed working** — all findings below were verified by live
> probing against opencode v2.1.0 on this machine.

---

## 1. The architecture (what actually runs)

```
  ~/.local/state/opencode/service.json
  { "url": "http://127.0.0.1:49374",
    "password": "<random per-launch>",
    "pid": 339277 }
          │
          │  REST + SSE  (the REAL API)
          ▼
  ┌───────────────────────┐      HTTP       ┌─────────────────────────────┐
  │  opencode serve       │ ◄─────────────► │  Node relay  (test1.js)     │
  │  --service            │                 │  POST /prompt               │
  │  (always running,     │   SSE /api/event│  GET  /stream  (fan-out)    │
  │   started by opencode │ ──────────────► │                             │
  │   on first launch)    │                 │  port: 3000                 │
  └───────────────────────┘                 └──────────────┬──────────────┘
                                                           │ SSE
                                                ┌──────────▼──────────────┐
                                                │  Flutter (test2.dart)   │
                                                │  OpenCodeRelayClient    │
                                                │  StreamBuilder UI       │
                                                └─────────────────────────┘

  ┌───────────────────────┐
  │  opencode serve       │  ← THIS is what --stdio --port 0 starts.
  │  --stdio --port 0     │    It serves the WEB UI (React SPA) only.
  │  (SPA web UI only)    │    The JSON it prints {"url":"..."} is the
  └───────────────────────┘    SPA port — NOT the API port. Don't use it.
```

### The critical discovery

Running `opencode serve --stdio --port 0` starts a **web UI server** (SPA),
not the REST API. Every path on that server returns the HTML shell — it is
a catch-all SPA router.

The **REST+SSE API** is the `--service` process which opencode starts
automatically. Its coordinates are written to:

```
~/.local/state/opencode/service.json
```

That file is re-created every time opencode starts, so the port **and**
the password change each launch (hence "per-launch password").

---

## 2. OPENCODE_DB — state paths

| path | what lives there |
|------|-----------------|
| `~/.local/share/opencode/opencode.db` | SQLite — all sessions, messages, costs |
| `~/.local/share/opencode/log/` | debug logs |
| `~/.local/state/opencode/service.json` | **per-launch** API URL + password + PID |
| `~/.local/state/opencode/session.json` | last active session |
| `~/.local/state/opencode/model.json` | last used model |
| `~/.config/opencode/opencode.json` | user config |
| `~/.config/opencode/service.json` | **static** service-level password (optional) |

Override the DB path:
```bash
OPENCODE_DB=/tmp/my-test.db opencode serve
```

Isolate parallel runs (avoids SQLite write-lock contention):
```bash
d=$(mktemp -d)
XDG_DATA_HOME="$d/share" XDG_STATE_HOME="$d/state" opencode serve
```

---

## 3. The per-launch password

opencode generates a **random password** on every service start and writes it
to `~/.local/state/opencode/service.json`. The relay reads this file at boot
so no manual credential passing is needed.

If you want a **static** password (useful for scripts that start opencode
themselves), set it in `~/.config/opencode/service.json`:
```json
{ "password": "your-static-password" }
```

HTTP Basic credentials:
```
username: opencode   (override with OPENCODE_SERVER_USERNAME env var)
password: <value from service.json>
```

---

## 4. The REST API

Base URL: `<service url>/api/...`  (the `/api` prefix is required)

### Endpoints used by the relay

| method | path | body / query | notes |
|--------|------|--------------|-------|
| `GET` | `/api/session` | `?limit&order&search&archived&project` | list sessions, wrapped in `{"data":[...]}` |
| `POST` | `/api/session` | `{"title","agent","model":{"id","providerID","variant"}}` | create session |
| `GET` | `/api/session/:id` | — | one session |
| `PATCH` | `/api/session/:id` | `{"title"}` | rename → `204` |
| `DELETE` | `/api/session/:id` | — | delete → `204` |
| `GET` | `/api/session/:id/message` | `?limit&order&cursor` | transcript, **newest first** by default |
| `POST` | `/api/session/:id/prompt` | `{"text","delivery","files","agents","skills"}` | send prompt → message object |
| `POST` | `/api/session/:id/command` | `{"name","text"}` | slash-command → `204` |
| `POST` | `/api/session/:id/interrupt` | — | stop execution → `{"interrupted":bool}` |
| `POST` | `/api/session/:id/fork` | `{"before"?}` | branch transcript |
| `POST` | `/api/session/:id/compact` | `{}` | compact context |
| `POST` | `/api/session/:id/model` | `{"model":{"id","providerID","variant"}}` | switch model → `204` |
| `POST` | `/api/session/:id/agent` | `{"agent"}` | switch agent → `204` |
| `GET` | `/api/session/active` | — | `{sessionID:{type:"running"}}` |
| `GET` | `/api/model` `/api/model/default` | — | model list / default model |
| `GET` | `/api/agent` | — | agent list (system prompts included) |
| `GET` | `/api/command` | — | slash-commands |
| `GET` | `/api/info` | — | version, pid, urls, capabilities |
| `GET` | `/api/event` | — | SSE stream, all bus events |

> **Model selection is not part of the prompt.** `POST …/prompt` only accepts
> `text`, `files`, `agents`, `skills`, `metadata`, `delivery` and `resume`.
> Passing `providerID`/`modelID` (or `model`) in the prompt body is silently
> ignored — you must call `POST …/model` first. The relay does this for you.

### Request / response shape

All responses are wrapped: `{ "data": <payload> }`.

The relay unwraps automatically — `oc()` returns `parsed.data`.

Every `204` means "success, no content" (rename, delete, model/agent switch).

### Confirmed SSE event types

Session lifecycle:

```
server.connected              — fires immediately after SSE subscribe
session.created               — a session was created {sessionID,title,...}
session.renamed               — title changed {sessionID,title}
session.deleted               — session removed {sessionID}
session.model.selected        — {sessionID, model:{id,providerID,variant}}
session.agent.selected        — {sessionID, agent}
session.updated               — session state changed
project.updated               — project metadata refresh
```

A single prompt:

```
session.inbox.enqueued        — prompt queued {sessionID, inboxID, item}
session.execution.started     — work begins
session.instructions.updated  — system prompt built
session.inbox.delivered       — prompt handed to the runner
session.step.started          — inference starts {model:{id,providerID}}
session.reasoning.started     — reasoning stream opens
session.reasoning.delta ×N    — {delta}
session.reasoning.ended
session.text.started          — text stream opens
session.text.delta ×N         — {delta}  ← the streaming token
session.text.ended            — {text}   ← ground truth
session.step.streamed         — stream closed
session.step.ended            — finish reason + tokens
session.tool.called / .input.started / .input.ended / .progress / .success
session.usage.updated         — cumulative cost/tokens
session.execution.succeeded   — done
session.execution.failed      — error
session.execution.interrupted — stopped via /interrupt
```

All session-scoped events carry `data.sessionID` at the top of `data`.

---

## 5. File inventory

| file | role |
|------|------|
| `relay/index.js` | Node relay — reads service.json, exposes the session API, bridges the event bus to Flutter over SSE |
| `relay/package.json` | Pinned deps: express, node-fetch 2.x |
| `flutter/lib/opencode_client.dart` | API layer — typed events, session ops, SSE client (widget-free, unit-tested) |
| `flutter/lib/main.dart` | Flutter UI — session sidebar, transcript, composer, model/agent pickers |
| `flutter/test/widget_test.dart` | JSON → model mapping tests (no relay needed) |
| `scripts/relay.sh` | Bootstrap — reads service.json, kills stale port, starts relay |
| `scripts/flutter.sh` | Installs Flutter if missing, then runs the web target in Chrome |
| `docs/SPIKE.md` | This document |

---

## 6. Reproducing end-to-end

### Prerequisites

```bash
opencode --version   # must be v2.x; must have been run at least once
node --version       # >= 16
flutter --version    # >= 3.x
```

For the Linux desktop target, also: `clang`, `cmake`, `ninja-build`,
`pkg-config`, `libgtk-3-dev`, `libstdc++-12-dev` (see README → *Running as a
Linux desktop app* for why the GCC version matters).

### Step 1 — start the relay

```bash
cd /path/to/opencode-spike
./scripts/relay.sh
```

`scripts/relay.sh`:
1. Reads `~/.local/state/opencode/service.json`
2. Verifies the service PID is alive
3. Kills any stale process on port 3000
4. `npm install` if needed
5. Starts `node relay/index.js` (the relay reads service.json itself)

### Step 2 — verify

```bash
# Health check (Terminal 2)
curl -s http://127.0.0.1:3000/health | jq

# Watch SSE stream (Terminal 2)
curl -sN http://127.0.0.1:3000/stream

# Send a prompt (Terminal 3)
curl -s -X POST http://127.0.0.1:3000/prompt \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "Say hello in one sentence"}' | jq
```

Expected SSE output in Terminal 2:
```
data: {"type":"server.connected","data":{}}
: heartbeat
data: {"type":"session.created",...}
data: {"type":"project.updated",...}
data: {"type":"session.inbox.enqueued",...}
```

### Step 3 — run the Flutter app

The app lives in `flutter/` (`lib/main.dart`) and already declares
`http: ^1.2.1` and `fetch_client: ^1.2.1` in `pubspec.yaml`.

**Web target:**

```bash
cd flutter
flutter run -d chrome --web-port 8080
```

`scripts/flutter.sh` does the same, installing Flutter first if missing.

**Linux desktop target (no APK, no emulator):**

```bash
flutter config --enable-linux-desktop
flutter create --platforms=linux --project-name opencode_flutter_spike .
flutter run -d linux
```

Desktop needs no CORS headers and does not use Chrome; it talks to the relay
over a plain socket with `http.Client`. Android emulator: change `kRelayUrl`
from `127.0.0.1` to `10.0.2.2`.

---

## 7. What to build next

- ~~**Session selector**~~ — done: the relay exposes `/sessions` and the app
  lists, creates, renames, forks and deletes sessions.
- **Slash-command palette** — `GET /commands` and
  `POST /sessions/:id/command` are already wired in the relay; the UI only
  needs a picker.
- **Permission prompts** — opencode emits `session.permission.*` events and
  exposes `/api/session/:id/permission/:requestID/reply`; render the request
  and reply from the app so tool approvals don't need the TUI.
- **Incremental transcript** — render `session.reasoning.*` and
  `session.tool.*` events live instead of reloading the transcript at the end
  of every turn (the reload is currently the accuracy guarantee).
- **OPENCODE_DB isolation** — use `XDG_DATA_HOME` override in `run.sh`
  to give each test run its own DB and avoid polluting personal history.
- **Static password** — write `~/.config/opencode/service.json` once so
  CI scripts don't need to re-read `service.json` after each restart.
