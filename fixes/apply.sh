#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-cloud.skmatcloud.com}"
CADDYFILE="/etc/caddy/Caddyfile"
HEALTH="/_health"

echo "[INFO] Applying Caddy fixes for $DOMAIN"

backup="${CADDYFILE}.bak.$(date +%F_%H-%M-%S)"
cp -a "$CADDYFILE" "$backup" || true

tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp".*' EXIT
cp -f "$CADDYFILE" "$tmp"

# Clean stray broken lines from earlier paste accidents
sed -i -E '/^\.\\"ho |^\."\s*ho /d' "$tmp"

# Remove ambiguous ':80, :443 { … }' block
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

# Ensure single :80 block with health + 404
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

# Configure cloud.skmatcloud.com block for Nextcloud (PHP-FPM / Docker) or fallback
PHPFPM_SOCK="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)"
HAS_DOCKER="false"; command -v docker >/dev/null 2>&1 && HAS_DOCKER="true"
NEXTCLOUD_DOCKER="false"
if [[ "$HAS_DOCKER" == "true" ]] && docker ps --format '{{.Names}}' | grep -qi '^nextcloud$'; then
  NEXTCLOUD_DOCKER="true"
fi

# remove old domain block
sed -i -E "/^${DOMAIN//./\\.}[[:space:]]*\\{/,/^\\}/d" "$tmp"

if [[ -d /var/www/nextcloud && -n "$PHPFPM_SOCK" ]]; then
  cat >> "$tmp" <<EOF

${DOMAIN} {
    root * /var/www/nextcloud
    encode gzip
    php_fastcgi unix/${PHPFPM_SOCK}
    file_server

    @health path ${HEALTH}
    respond @health "OK" 200

    handle_path /.well-known/carddav   { redir /remote.php/dav 301 }
    handle_path /.well-known/caldav    { redir /remote.php/dav 301 }
    handle_path /.well-known/webfinger { redir /index.php/.well-known/webfinger 301 }
    handle_path /.well-known/nodeinfo  { redir /index.php/.well-known/nodeinfo 301 }
}
EOF
elif [[ "$NEXTCLOUD_DOCKER" == "true" ]]; then
  TARGET="$(docker port nextcloud 2>/dev/null | awk -F' -> ' '/0\.0\.0\.0|127\.0\.0\.1/ {print $2}' | head -n1)"
  [[ -n "$TARGET" ]] || TARGET="nextcloud:80"
  cat >> "$tmp" <<EOF

${DOMAIN} {
    encode gzip
    @health path ${HEALTH}
    respond @health "OK" 200
    reverse_proxy ${TARGET}
}
EOF
else
  UPSTREAM="127.0.0.1:8080"
  cat >> "$tmp" <<EOF

${DOMAIN} {
    encode gzip
    @health path ${HEALTH}
    respond @health "OK" 200
    reverse_proxy ${UPSTREAM}
}
EOF
fi

# Write back
cp -f "$tmp" "$CADDYFILE"
echo "[INFO] Caddyfile updated (workflow will validate & reload)."
