#!/usr/bin/env bash
# scripts/edge.sh — start the TLS edge (QUIC + HTTP/2) in front of the relay
#
# Run from repo root:
#   chmod +x scripts/edge.sh && ./scripts/edge.sh
#
# This is terminal 2 of three. Order matters:
#   1. ./scripts/relay.sh     plaintext Express relay on 127.0.0.1:3000
#   2. ./scripts/edge.sh      this — UDP+TCP 3443, proxying to 3000
#   3. flutter run -d linux   the desktop app, which prefers QUIC on 3443
#
# The desktop app defaults to https://localhost:3443, so without this script it
# cannot connect at all. (The web target still uses http://127.0.0.1:3000.)
#
# Env vars (all optional):
#   EDGE_PORT     port to serve on        (default: 3443)
#   RELAY_PORT    upstream relay port     (default: 3000)
#   CADDY         caddy binary to use     (default: tools/bin/caddy)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDGE_PORT="${EDGE_PORT:-3443}"
RELAY_PORT="${RELAY_PORT:-3000}"
CADDY_VERSION="2.11.7"
CADDY_DIR="$REPO_ROOT/tools/bin"
CADDY_BIN="${CADDY:-$CADDY_DIR/caddy}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenCode Spike — TLS edge (QUIC + HTTP/2)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Get a caddy binary ─────────────────────────────────────────────────────

if [ ! -x "$CADDY_BIN" ]; then
  echo ""
  echo "▶  Downloading Caddy v$CADDY_VERSION into tools/bin …"
  mkdir -p "$CADDY_DIR"
  TARBALL="$(mktemp -t caddy.XXXXXX.tgz)"
  URL="https://github.com/caddyserver/caddy/releases/download/v$CADDY_VERSION/caddy_${CADDY_VERSION}_linux_amd64.tar.gz"
  curl -fsSL "$URL" -o "$TARBALL"
  tar -xzf "$TARBALL" -C "$CADDY_DIR" caddy
  rm -f "$TARBALL"
  chmod +x "$CADDY_BIN"
fi

echo "   caddy: $("$CADDY_BIN" version)"

# ── 2. Warn if the relay is not up yet ────────────────────────────────────────

if ! (exec 3<>"/dev/tcp/127.0.0.1/$RELAY_PORT") 2>/dev/null; then
  echo ""
  echo "⚠  Nothing is listening on 127.0.0.1:$RELAY_PORT — start ./scripts/relay.sh first."
  echo "   (The edge will still start and return 502 until the relay is up.)"
fi

# ── 3. Start ──────────────────────────────────────────────────────────────────

echo ""
echo "▶  Edge listening on https://localhost:$EDGE_PORT"
echo "     QUIC / HTTP-3   UDP $EDGE_PORT"
echo "     HTTP/2          TCP $EDGE_PORT"
echo "     proxying to     http://127.0.0.1:$RELAY_PORT"
echo ""
echo "   Verify the token stream end to end:"
echo "     curl -skN --http3 https://localhost:$EDGE_PORT/stream   # QUIC"
echo "     curl -skN --http2 https://localhost:$EDGE_PORT/stream   # fallback"
echo ""
echo "   Certificate: Caddy's local CA (self-signed). The app skips verification"
echo "   for this loopback edge; curl needs -k."
echo ""

export EDGE_PORT RELAY_PORT
trap 'echo ""; echo "⏹  Edge stopped."; exit 0' INT TERM

exec "$CADDY_BIN" run --config "$REPO_ROOT/relay/Caddyfile" --adapter caddyfile
