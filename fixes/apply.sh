#!/usr/bin/env bash
set -euo pipefail

EMAIL="admin@cloud.skmatcloud.com"
DOMAIN_ROOT="skmatcloud.com"
CADDYFILE="/etc/caddy/Caddyfile"
CADDY_TMP="/etc/caddy/Caddyfile.tmp"

i(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
w(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }
e(){ echo -e "\e[1;31m[ERR]\e[0m  $*"; }

need(){ command -v "$1" >/dev/null 2>&1 || { e "Missing: $1"; exit 1; }; }
need docker
need curl

# dockerized validators (avoid host glibc)
caddy_validate(){
  docker run --rm \
    -v /etc/caddy:/etc/caddy:ro \
    caddy:2 caddy validate --adapter caddyfile --config "$CADDY_TMP"
}

caddy_reload(){
  if curl -fsS http://127.0.0.1:2019/config >/dev/null 2>&1; then
    # Adapt to JSON then stream to Admin API (no tmp files)
    docker run --rm -v /etc/caddy:/etc/caddy:ro caddy:2 \
      caddy adapt --adapter caddyfile --config "$CADDYFILE" \
    | docker run --rm --network host curlimages/curl:latest \
      -sS -X POST -H 'Content-Type: application/json' --data-binary @- \
      http://127.0.0.1:2019/load >/dev/null
  else
    systemctl restart caddy
  fi
}

# Map subdomain -> local port
declare -A MAP=(
  [portainer]=9001
  [kuma]=3001
  [dozzle]=9999
  [cadvisor]=84
  [admin]=85
  [espocrm]=14080
  [picpeak]=3000
  [picpeak-api]=5000
  [dev]=8443
)

# Preserve Nextcloud backend IP
NEXTCLOUD_CTN="nextcloud-app-1"
NEXT_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NEXTCLOUD_CTN" 2>/dev/null || true)"
if [[ -z "$NEXT_IP" && -f "$CADDYFILE" ]]; then
  NEXT_IP="$(grep -Eo 'reverse_proxy[[:space:]]+http://([0-9]{1,3}\.){3}[0-9]{1,3}:80' "$CADDYFILE" | head -n1 | sed -E 's#.*http://##; s/:80.*##')"
fi
[[ -z "$NEXT_IP" ]] && { e "Cannot determine Nextcloud IP; aborting to avoid breaking cloud."; exit 0; }

# Detect dev proto
DEV_PROTO="https"
if ! curl -ksS -o /dev/null https://127.0.0.1:8443/; then
  DEV_PROTO="http"
fi

# Backup then build strict Caddyfile -> write FIRST to CADDY_TMP
ts="$(date +%F_%H-%M-%S)"
[[ -f "$CADDYFILE" ]] && cp -a "$CADDYFILE" "${CADDYFILE}.bak.${ts}" || true
i "Backup: ${CADDYFILE}.bak.${ts}"

emit_http(){
  local host="$1" port="$2"
  cat <<V
${host}
{
    tls internal
    encode gzip zstd
    handle_path /_health* { respond "OK" 200 }
    reverse_proxy http://127.0.0.1:${port} {
        transport http { versions 1.1 }
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        X-Frame-Options "SAMEORIGIN"
    }
}
V
}

emit_https(){
  local host="$1" port="$2"
  cat <<V
${host}
{
    tls internal
    encode gzip zstd
    handle_path /_health* { respond "OK" 200 }
    reverse_proxy https://127.0.0.1:${port} {
        transport http {
            tls_insecure_skip_verify
            versions 1.2 1.3
        }
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        X-Frame-Options "SAMEORIGIN"
    }
}
V
}

{
  cat <<GLOBAL
{
    admin 127.0.0.1:2019
    email ${EMAIL}
}
GLOBAL

  # Nextcloud (use preserved IP)
  emit_http "cloud.${DOMAIN_ROOT}" 80 | sed -E "s#http://127\.0\.0\.1:80#http://${NEXT_IP}:80#"

  # Other vhosts
  for sub in "${!MAP[@]}"; do
    [[ "$sub" == "cloud" ]] && continue
    host="${sub}.${DOMAIN_ROOT}"
    port="${MAP[$sub]}"
    if [[ "$sub" == "dev" ]]; then
      [[ "$DEV_PROTO" == "https" ]] && emit_https "$host" "$port" || emit_http "$host" "$port"
    else
      emit_http "$host" "$port"
    fi
  done

  # Catch-all HTTP
  cat <<'CATCH'
:80
{
    respond "Not configured" 404
}
CATCH
} > "$CADDY_TMP"

i "Validating Caddyfile (dockerized)…"
caddy_validate

# Promote tmp to live and reload
cp -f "$CADDY_TMP" "$CADDYFILE"
i "Reloading Caddy…"
caddy_reload

# Probes (SNI + HTTP/1.1)
DOMS=(cloud.${DOMAIN_ROOT} portainer.${DOMAIN_ROOT} kuma.${DOMAIN_ROOT} dozzle.${DOMAIN_ROOT} cadvisor.${DOMAIN_ROOT} admin.${DOMAIN_ROOT} espocrm.${DOMAIN_ROOT} picpeak.${DOMAIN_ROOT} picpeak-api.${DOMAIN_ROOT} dev.${DOMAIN_ROOT})

echo
i "SNI /_health (HTTP/1.1, bypass CF):"
for d in "${DOMS[@]}"; do
  code=$(curl --http1.1 -ksS --resolve "${d}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${d}/_health" || echo 000)
  printf "%-28s https:%s\n" "$d" "$code"
done

echo
i "SNI homepage (HTTP/1.1):"
for d in "${DOMS[@]}"; do
  code=$(curl --http1.1 -ksS --resolve "${d}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${d}/" || echo 000)
  printf "%-28s https:%s\n" "$d" "$code"
done

exit 0
