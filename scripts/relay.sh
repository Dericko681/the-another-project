#!/usr/bin/env bash
# scripts/relay.sh — start the Node relay
#
# Run from repo root:
#   chmod +x scripts/relay.sh && ./scripts/relay.sh
#
# The relay reads opencode credentials automatically from:
#   ~/.local/state/opencode/service.json
# No env vars needed unless overriding.
#
# Env vars (all optional):
#   RELAY_PORT        port the relay listens on   (default: 3000)
#   OPENCODE_URL      override API URL
#   OPENCODE_PASSWORD override password

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_DIR="$REPO_ROOT/relay"
RELAY_PORT="${RELAY_PORT:-3000}"
SERVICE_JSON="${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenCode Spike — Relay"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Check opencode service is alive ────────────────────────────────────────

echo ""
echo "▶  Checking opencode service …"

if [ ! -f "$SERVICE_JSON" ]; then
  echo "✗  $SERVICE_JSON not found."
  echo "   Launch opencode at least once first to create this file."
  exit 1
fi

OC_URL=$(node -e "process.stdout.write(require('$SERVICE_JSON').url)")
OC_PID=$(node -e "process.stdout.write(String(require('$SERVICE_JSON').pid))")

if [ -z "$OC_URL" ]; then
  echo "✗  Could not read URL from $SERVICE_JSON"
  exit 1
fi

if ! kill -0 "$OC_PID" 2>/dev/null; then
  echo "✗  opencode service (pid $OC_PID) is not running."
  echo "   Open the opencode TUI or web UI once, then retry."
  exit 1
fi

echo "   opencode API: $OC_URL  (pid $OC_PID)"

# ── 2. Kill anything already on our port ─────────────────────────────────────

STALE=$(node -e "
const net = require('net');
const s = net.createServer();
s.once('error', () => process.stdout.write('inuse'));
s.once('listening', () => { s.close(); process.stdout.write('free'); });
s.listen($RELAY_PORT);
")

if [ "$STALE" = "inuse" ]; then
  echo ""
  echo "▶  Port $RELAY_PORT in use — killing existing process …"
  node -e "
    const { execSync } = require('child_process');
    try { execSync('fuser -k ${RELAY_PORT}/tcp 2>/dev/null'); } catch {}
    setTimeout(() => {}, 500);
  " || true
  sleep 0.5
fi

# ── 3. Install deps if needed ─────────────────────────────────────────────────

cd "$RELAY_DIR"

if [ ! -d node_modules ]; then
  echo ""
  echo "▶  Installing relay dependencies …"
  npm install --silent
fi

# ── 4. Start ──────────────────────────────────────────────────────────────────

echo ""
echo "▶  Starting relay on http://127.0.0.1:$RELAY_PORT"
echo ""
echo "   Endpoints:"
echo "     GET    /sessions                list sessions"
echo "     POST   /sessions                create session"
echo "     PATCH  /sessions/:id            rename"
echo "     DELETE /sessions/:id            delete"
echo "     GET    /sessions/:id/messages   transcript"
echo "     POST   /sessions/:id/prompt     send a prompt"
echo "     POST   /sessions/:id/interrupt  stop execution"
echo "     POST   /sessions/:id/fork|compact|model|agent"
echo "     GET    /models /agents /commands /active"
echo "     POST   /prompt                  legacy single-session prompt"
echo "     GET    /stream                  SSE stream for Flutter"
echo "     GET    /health                  liveness check"
echo ""
echo "   Quick test (in another terminal):"
echo "     curl -s http://127.0.0.1:$RELAY_PORT/health | jq"
echo "     curl -s http://127.0.0.1:$RELAY_PORT/sessions | jq"
echo "     curl -sN http://127.0.0.1:$RELAY_PORT/stream"
echo "     curl -s -X POST http://127.0.0.1:$RELAY_PORT/prompt \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"prompt\":\"Explain closures in one sentence\"}'"
echo ""

export RELAY_PORT
trap 'echo ""; echo "⏹  Relay stopped."; exit 0' INT TERM
node index.js
