#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/skm-autofix"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "[INFO] SKM Auto-Fix start: $(date -u +%F_%T)"

CADDYFILE="/etc/caddy/Caddyfile"

# 1) Validate Caddyfile using official image (no host glibc needed)
echo "[INFO] Validating Caddyfile with docker image caddy:2…"
docker run --rm \
  -v /etc/caddy:/etc/caddy:ro \
  caddy:2 \
  caddy validate --adapter caddyfile --config "$CADDYFILE"

echo "[OK] Validation passed."

# 2) Hot reload the host Caddy via admin API using host networking
#    (Caddy admin defaults to 127.0.0.1:2019)
echo "[INFO] Hot reloading Caddy via admin API…"
docker run --rm --network host \
  -v /etc/caddy:/etc/caddy:ro \
  caddy:2 \
  caddy reload --adapter caddyfile --config "$CADDYFILE" --address 127.0.0.1:2019

echo "[OK] Reload sent."

# 3) Health probe
DOMAIN="${DOMAIN:-cloud.skmatcloud.com}"
echo "[INFO] Probing https://${DOMAIN}/_health"
curl -fsS -k "https://${DOMAIN}/_health" && echo "[OK] Health endpoint responds" || echo "[WARN] Health probe failed"

echo "[DONE] SKM Auto-Fix completed: $(date -u +%F_%T) — log: $LOG"
