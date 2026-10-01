#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 09-health-check.sh [--wait]
# Check every hop of the chain:
#   Author :4502 | Publish :4503 | Dispatcher :9999 → Publish
#   nginx https://<domain> → Dispatcher → Publish | /etc/hosts
# --wait : poll until healthy or HEALTH_TIMEOUT seconds (AEM first boot is slow)
# ─────────────────────────────────────────────────────────────

source "$(dirname "$0")/lib/common.sh"

WAIT=0; [[ "$1" == "--wait" ]] && WAIT=1
HOSTS_FILE=/etc/hosts; [[ "$OS" == "windows" ]] && HOSTS_FILE=/c/Windows/System32/drivers/etc/hosts
SUFFIX=""; [[ "$NGINX_HTTPS_PORT" != "443" ]] && SUFFIX=":${NGINX_HTTPS_PORT}"
ERRORS=0

pass() { echo -e "  ${GREEN}✔${RESET} $*"; }
bad()  { echo -e "  ${RED}✘${RESET} $*"; ERRORS=$((ERRORS+1)); }

# check <label> <accepted-codes-regex> <curl args...>
check() {
  local label="$1" ok_re="$2"; shift 2
  local code; code="$(http_code "$@")"
  if [[ "$code" =~ ^(${ok_re})$ ]]; then pass "${label} → HTTP ${code}"
  else bad "${label} → HTTP ${code:-000}"; fi
}

run_checks() {
  ERRORS=0
  echo -e "  ${BOLD}AEM${RESET}"
  check "Author   http://localhost:${AEM_AUTHOR_PORT}"  "200" \
        "http://localhost:${AEM_AUTHOR_PORT}/libs/granite/core/content/login.html"
  check "Publish  http://localhost:${AEM_PUBLISH_PORT}" "200|302|401|403" \
        "http://localhost:${AEM_PUBLISH_PORT}/libs/granite/core/content/login.html"

  echo -e "  ${BOLD}Docker${RESET}"
  local derr
  if derr="$(docker info 2>&1 >/dev/null)"; then
    for c in aem-dispatcher aem-nginx; do
      local st; st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
      [[ "$st" == "running" ]] && pass "container ${c}: running" || bad "container ${c}: ${st}"
    done
  else
    # `docker info` failing ≠ daemon down: often this shell just can't reach it.
    # Show the real reason instead of guessing.
    local why; why="$(echo "$derr" | grep -m1 -iE 'denied|cannot connect|is the docker daemon|error' || echo "$derr" | tail -n 1)"
    bad "Docker CLI cannot reach the daemon from this shell: ${why:-unknown error}"
    if [[ "$derr" == *"permission denied"* ]]; then
      info "→ this terminal predates your 'docker' group membership: open a new login shell"
      info "  (log out/in, or restart the IDE that owns this terminal), or run: newgrp docker"
    elif [[ "$derr" == *"Cannot connect"* || "$derr" == *"Is the docker daemon running"* ]]; then
      info "→ check the daemon (linux: systemctl status docker · mac/win: Docker Desktop) and context: docker context show"
    fi
  fi

  # Any real response from httpd means dispatcher is up; 502/503 = can't reach publish
  echo -e "  ${BOLD}Dispatcher${RESET}"
  check "Dispatcher http://localhost:${DISPATCHER_PORT}" "[1-4][0-9][0-9]" \
        "http://localhost:${DISPATCHER_PORT}/"

  echo -e "  ${BOLD}nginx (SSL) → Dispatcher → Publish${RESET}"
  for d in $CUSTOM_DOMAINS; do
    check "https://${d}${SUFFIX}" "[1-4][0-9][0-9]" \
          --resolve "${d}:${NGINX_HTTPS_PORT}:127.0.0.1" "https://${d}${SUFFIX}/"
  done

  echo -e "  ${BOLD}Hosts / cert${RESET}"
  for d in $CUSTOM_DOMAINS; do
    grep -qE "^[[:space:]]*127\.0\.0\.1([[:space:]]+[^[:space:]#]+)*[[:space:]]+${d//./\\.}([[:space:]]|#|$)" "$HOSTS_FILE" 2>/dev/null \
      && pass "${d} in ${HOSTS_FILE}" || bad "${d} missing from ${HOSTS_FILE} (make hosts)"
  done
  if [[ -f "$CERT_FILE" ]]; then
    local sans before=$ERRORS
    sans="$(openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -1)"
    for d in $CUSTOM_DOMAINS; do
      [[ "$sans" == *"DNS:${d}"* ]] || bad "cert ${CERT_FILE} does not cover ${d} (FORCE=1 make certs)"
    done
    (( ERRORS == before )) && pass "cert $(rel "$CERT_FILE") covers all domains"
  else
    bad "cert $(rel "$CERT_FILE") missing (make certs)"
  fi
}

step "Health check"

if (( WAIT )); then
  START=$(date +%s); OUT="$(mktemp)"
  until run_checks >"$OUT" 2>&1; (( ERRORS == 0 )); do
    ELAPSED=$(( $(date +%s) - START ))
    if (( ELAPSED >= HEALTH_TIMEOUT )); then break; fi
    printf "\r    waiting for services... %ss (%s issue(s))   " "$ELAPSED" "$ERRORS"
    sleep 10
  done
  printf "\r%60s\r" ""
  cat "$OUT"; rm -f "$OUT"
else
  run_checks
fi

echo ""
if (( ERRORS == 0 )); then
  echo -e "  ${GREEN}${BOLD}All services healthy.${RESET}"
  echo ""
  info "Author     ${CYAN}http://localhost:${AEM_AUTHOR_PORT}${RESET}  (admin/admin)"
  info "Publish    ${CYAN}http://localhost:${AEM_PUBLISH_PORT}${RESET}"
  info "Dispatcher ${CYAN}http://localhost:${DISPATCHER_PORT}${RESET}"
  for d in $CUSTOM_DOMAINS; do info "Site       ${CYAN}https://${d}${SUFFIX}${RESET}"; done
  echo ""
  exit 0
fi
echo -e "  ${RED}${BOLD}${ERRORS} issue(s) found.${RESET} AEM first boot can take 5-10 min — retry: ${CYAN}make health${RESET}"
echo ""
exit 1
