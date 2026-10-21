#!/usr/bin/env bash
# scripts/flutter.sh — install Flutter (once) and run the spike app in Chrome
#
# Run from repo root:
#   chmod +x scripts/flutter.sh && ./scripts/flutter.sh
#
# Prerequisites:
#   - The relay must be running first:  ./scripts/relay.sh
#   - Chrome must be installed (used as the Flutter web target)
#
# Env vars (optional):
#   FLUTTER_DIR   where Flutter is / will be installed  (default: ~/flutter)
#   FLUTTER_PORT  port for the web app                  (default: 8080)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_APP_DIR="$REPO_ROOT/flutter"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
FLUTTER_BIN="$FLUTTER_DIR/bin/flutter"
FLUTTER_PORT="${FLUTTER_PORT:-8080}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenCode Spike — Flutter App"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Install Flutter if missing ─────────────────────────────────────────────

if [ ! -f "$FLUTTER_BIN" ]; then
  echo ""
  echo "▶  Flutter not found — installing to $FLUTTER_DIR …"
  echo "   (~700 MB download, one-time only)"

  FLUTTER_VERSION="3.24.3"
  TARBALL="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${TARBALL}"

  echo "   Downloading Flutter $FLUTTER_VERSION …"
  curl -L -o "/tmp/$TARBALL" "$URL"
  echo "   Extracting …"
  tar xf "/tmp/$TARBALL" -C "$HOME"
  rm "/tmp/$TARBALL"
  echo "   Installed at $FLUTTER_DIR"
else
  echo ""
  echo "▶  Flutter found: $("$FLUTTER_BIN" --version 2>/dev/null | head -1)"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

# ── 2. Configure Flutter ──────────────────────────────────────────────────────

flutter config --no-analytics > /dev/null 2>&1 || true
flutter config --enable-web   > /dev/null 2>&1 || true

# ── 3. Get Dart dependencies ──────────────────────────────────────────────────

cd "$FLUTTER_APP_DIR"

echo ""
echo "▶  Getting Flutter dependencies …"
flutter pub get

# ── 4. Check relay is up ──────────────────────────────────────────────────────

echo ""
echo "▶  Checking relay …"
if curl -s --max-time 2 http://127.0.0.1:3000/health > /dev/null 2>&1; then
  echo "   Relay is up at http://127.0.0.1:3000 ✓"
else
  echo ""
  echo "⚠  Relay is NOT running!"
  echo "   Open a second terminal and run:  ./scripts/relay.sh"
  echo ""
  read -r -p "   Continue anyway? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

# ── 5. Launch in Chrome ───────────────────────────────────────────────────────

echo ""
echo "▶  Launching Flutter app in Chrome …"
echo "   URL: http://localhost:$FLUTTER_PORT"
echo "   Press r to hot-reload, R to hot-restart, q to quit."
echo ""

flutter run \
  --device-id chrome \
  --web-port "$FLUTTER_PORT" \
  --web-hostname localhost
