#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/skm-autofix"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(date +%F_%H-%M-%S).log"
exec > >(tee -a "$LOG") 2>&1

echo "[INFO] SKM Auto-Fix start: $(date -u +%F_%T)"
CADDYFILE="/etc/caddy/Caddyfile"
HEALTH="/_health"
DOMAIN="${DOMAIN:-cloud.skmatcloud.com}"

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "[INFO] Installing docker CLI in runner..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io curl ca-certificates
  fi
}

normalize_caddy() {
  echo "[INFO] Normalising Caddyfile…"
  tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp".*' RETURN
  cp -f "$CADDYFILE" "$tmp"

  # Remove accidental garbage lines from earlier paste accidents
  sed -i -E '/^\.\\"ho |^\."\s*ho /d' "$tmp"

  # Remove ambiguous ":80, :443 { ... }" block
  awk '
    BEGIN{drop=0; depth=0}
    /^[[:space:]]*:80[[:space:]]*,[[:space:]]*:443[[:space:]]*\{/ {drop=1; depth=1; next}
    {
      if(drop){
        for(i=1;i<=length($0);i++){
          c=substr($0,i,1)
          if(c=="{") depth++
          else if(c=="}") depth--
        }
        if(depth<=0){ drop=0 }
        next
      }
      print
    }
  ' "$tmp" > "$tmp.1" && mv "$tmp.1" "$tmp"

  # Ensure single :80 block with health and 404
  if grep -qE '^[[:space:]]*:80[[:space:]]*\{' "$tmp"; then
    if ! awk "/^[[:space:]]*:80[[:space:]]*\\{/,/^\\}/ {print}" "$tmp" | grep -q "$HEALTH"; then
      awk -v hp="$HEALTH" '
        /^[[:space:]]*:80[[:space:]]*\{/ {print; print "    handle_path " hp "* {"; print "        respond \"OK\" 200"; print "    }"; next}
        {print}
      ' "$tmp" > "$tmp.2" && mv "$tmp.2" "$tmp"
    fi
  else
    {
      echo
      echo ":80 {"
      echo "    handle_path ${HEALTH}* {"
      echo "        respond \"OK\" 200"
      echo "    }"
      echo "    respond \"Not configured\" 404"
      echo "}"
    } >> "$tmp"
  fi

  # Helper to upsert a vhost
  upsert_block() {
    local host="$1"; shift
    local body="$*"
    sed -i -E "/^${host//./\\.}[[:space:]]*\\{/,/^\\}/d" "$tmp"
    printf "\n%s {\n%s\n}\n" "$host" "$body" >> "$tmp"
  }

  # Admin/dev subdomains (safe defaults)
  upsert_block "dev.skmatcloud.com" $'    encode gzip\n    @health path /_health\n    respond @health "OK" 200\n    reverse_proxy 127.0.0.1:8443'
  upsert_block "portainer.skmatcloud.com" $'    reverse_proxy 127.0.0.1:9001'
  upsert_block "kuma.skmatcloud.com" $'    reverse_proxy 127.0.0.1:3001'
  upsert_block "dozzle.skmatcloud.com" $'    reverse_proxy 127.0.0.1:9999'
  upsert_block "cadvisor.skmatcloud.com" $'    reverse_proxy 127.0.0.1:84'
  upsert_block "admin.skmatcloud.com" $'    reverse_proxy 127.0.0.1:85'

  # Detect Nextcloud (php-fpm or docker), else use CLOUD_UPSTREAM or 127.0.0.1:8080
  PHPFPM_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"
  HAS_DOCKER="false"; command -v docker >/dev/null 2>&1 && HAS_DOCKER="true"
  NEXTCLOUD_DOCKER="false"
  if [[ "$HAS_DOCKER" == "true" ]] && docker ps --format '{{.Names}}' | grep -qi '^nextcloud$'; then
    NEXTCLOUD_DOCKER="true"
  fi
  CLOUD_UPSTREAM_DEFAULT="127.0.0.1:8080"
  CLOUD_UPSTREAM="${CLOUD_UPSTREAM:-$CLOUD_UPSTREAM_DEFAULT}"

  if [[ -d /var/www/nextcloud && -n "$PHPFPM_SOCK" ]]; then
    echo "[INFO] Using Nextcloud via php-fpm ($PHPFPM_SOCK)"
    upsert_block "$DOMAIN" $'    root * /var/www/nextcloud\n    encode gzip\n    php_fastcgi unix/'"$PHPFPM_SOCK"$'\n    file_server\n\n    @health path /_health\n    respond @health "OK" 200\n\n    handle_path /.well-known/carddav   { redir /remote.php/dav 301 }\n    handle_path /.well-known/caldav    { redir /remote.php/dav 301 }\n    handle_path /.well-known/webfinger { redir /index.php/.well-known/webfinger 301 }\n    handle_path /.well-known/nodeinfo  { redir /index.php/.well-known/nodeinfo 301 }'
  elif [[ "$NEXTCLOUD_DOCKER" == "true" ]]; then
    TARGET="$(docker port nextcloud 2>/dev/null | awk -F' -> ' '/0\.0\.0\.0|127\.0\.0\.1/ {print $2}' | head -n1)"
    [[ -n "$TARGET" ]] || TARGET="nextcloud:80"
    echo "[INFO] Using Nextcloud docker upstream: $TARGET"
    upsert_block "$DOMAIN" $'    encode gzip\n    @health path /_health\n    respond @health "OK" 200\n    reverse_proxy '"$TARGET"
  else
    echo "[INFO] Using generic upstream: $CLOUD_UPSTREAM"
    upsert_block "$DOMAIN" $'    encode gzip\n    @health path /_health\n    respond @health "OK" 200\n    reverse_proxy '"$CLOUD_UPSTREAM"
  fi

  cp -f "$tmp" "$CADDYFILE"
}

validate_adapt_reload() {
  echo "[INFO] Validate via caddy:2"
  docker run --rm -v /etc/caddy:/etc/caddy:ro caddy:2 \
    caddy validate --adapter caddyfile --config "$CADDYFILE"

  echo "[INFO] Adapt -> JSON"
  docker run --rm -v /etc/caddy:/etc/caddy:ro caddy:2 \
    caddy adapt --adapter caddyfile --config "$CADDYFILE" > /tmp/caddy_adapt.json

  echo "[INFO] Reload via admin API"
  curl -fsS -H "Content-Type: application/json" --data-binary @/tmp/caddy_adapt.json \
    http://127.0.0.1:2019/load
}

health_probe() {
  echo "[INFO] Probing https://${DOMAIN}/_health"
  if curl -fsS -k "https://${DOMAIN}/_health" >/dev/null; then
    echo "[OK] Health 200"
  else
    echo "[WARN] Health failed, checking homepage head…"
    curl -sS -k -I -H "Host: ${DOMAIN}" https://127.0.0.1/ | head -n 5 || true
  fi
}

ensure_docker
normalize_caddy
validate_adapt_reload
health_probe
echo "[DONE] SKM Auto-Fix completed: $(date -u +%F_%T) — log: $LOG"
