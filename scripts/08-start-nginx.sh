#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 08-start-nginx.sh [start|stop|reload]
# Run the nginx SSL proxy container (docker compose service: nginx)
#   host :${NGINX_HTTPS_PORT} → container :443 (certs/) → aem-dispatcher:80
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx aem-nginx; }

test_config() {
  compose run --rm --no-deps -T nginx nginx -t >/dev/null 2>&1 \
    || { compose run --rm --no-deps -T nginx nginx -t; fail "nginx config test failed."; }
  ok "nginx config test passed."
}

case "${1:-start}" in
  start)
    step "Starting nginx SSL proxy"
    require_docker
    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] || fail "Cert missing ($(rel "$CERT_FILE")). Run: make certs"
    ls "$NGINX_CONF_DIR"/*.conf &>/dev/null || fail "No nginx config in $(rel "$NGINX_CONF_DIR"). Run: make nginx"

    if ! running; then
      for p in "$NGINX_HTTP_PORT" "$NGINX_HTTPS_PORT"; do
        port_open "$p" && fail "Port ${p} is in use. Stop that service or change NGINX_HTTP(S)_PORT in .env."
      done
    fi

    # nginx resolves aem-dispatcher at startup → dispatcher must be up
    compose up -d dispatcher >/dev/null 2>&1 || true
    test_config
    compose up -d nginx
    running && compose exec -T nginx nginx -s reload >/dev/null 2>&1 || true

    ok "nginx running"
    for d in $CUSTOM_DOMAINS; do info "${CYAN}$(site_url "$d")${RESET}"; done
    echo "" ;;
  reload)
    require_docker
    test_config
    compose exec -T nginx nginx -s reload && ok "nginx reloaded." ;;
  stop)
    step "Stopping nginx SSL proxy"
    compose stop nginx 2>/dev/null || true
    compose rm -f nginx >/dev/null 2>&1 || true
    ok "nginx stopped." ;;
  *) fail "Usage: $0 [start|stop|reload]" ;;
esac
