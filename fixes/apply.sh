#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/skm-autofix"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "[INFO] SKM Auto-Fix start: $(date -u +%F_%T)"
CADDYFILE="/etc/caddy/Caddyfile"
ADAPT_JSON="/tmp/caddy_adapt.json"

# Ensure docker CLI is present (runner container)
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Installing docker CLI inside runner..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io curl ca-certificates
fi

echo "[INFO] Validating Caddyfile via caddy:2 (adapt)..."
if ! docker run --rm -v /etc/caddy:/etc/caddy:ro caddy:2 caddy validate --adapter caddyfile --config "$CADDYFILE"; then
  echo "[ERR] Validation failed in container."
  exit 1
fi

echo "[INFO] Adapting Caddyfile -> JSON with caddy:2..."
docker run --rm -v /etc/caddy:/etc/caddy:ro caddy:2 \
  caddy adapt --adapter caddyfile --config "$CADDYFILE" > "$ADAPT_JSON"

echo "[INFO] Posting adapted config to admin API (127.0.0.1:2019/load)..."
curl -fsS -H "Content-Type: application/json" --data-binary @"$ADAPT_JSON" \
  http://127.0.0.1:2019/load && echo "[OK] Reloaded via admin API"

DOMAIN="${DOMAIN:-cloud.skmatcloud.com}"
echo "[INFO] Health probe https://${DOMAIN}/_health"
curl -fsS -k "https://${DOMAIN}/_health" && echo "[OK] Health endpoint responds" || echo "[WARN] Health probe failed"

echo "[DONE] SKM Auto-Fix completed: $(date -u +%F_%T) — log: $LOG"
