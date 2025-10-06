#!/usr/bin/env bash
set -euo pipefail
log="/var/log/skm-autofix-$(date +%F_%H-%M-%S).log"
mkdir -p /var/log
exec > >(tee -a "$log") 2>&1

echo "[INFO] Running SKM Auto-Fix at $(date)"

# 1) Validate Caddy config
if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  echo "[INFO] Caddyfile validation OK"
else
  echo "[ERR] Caddyfile invalid!"
  exit 1
fi

# 2) Reload Caddy
if systemctl reload caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile; then
  echo "[INFO] Caddy reloaded successfully"
else
  echo "[WARN] Could not reload via systemctl or CLI"
fi

# 3) Health probe
sleep 3
curl -fsSL "https://cloud.skmatcloud.com/_health" && echo "[INFO] Cloud responded OK" || echo "[WARN] Cloud not responding"

echo "[DONE] Auto-Fix completed at $(date)"
