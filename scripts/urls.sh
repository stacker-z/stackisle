#!/bin/bash
# ─────────────────────────────────────────────────────────────
# scripts/urls.sh [urls|smoke]          (make urls · make smoke)
# All URLs are built from .env (LOCAL_HOSTNAME, ports, CUSTOM_DOMAINS,
# NGINX_HTTPS_PORT, SMOKE_PATH, AEM_LOGIN_PATH) — nothing hardcoded.
#   urls   print every URL of this setup
#   smoke  test each hop on SMOKE_PATH and print the exact curl used,
#          so it can be re-run or adapted by hand
# ─────────────────────────────────────────────────────────────

source "$(dirname "$0")/lib/common.sh"

ERRORS=0
# Shown in printed commands instead of the real password
AUTH_SHOWN="${AEM_ADMIN_USER}:***"

cmd_urls() {
  step "URLs (from .env)"
  info "${BOLD}Sites${RESET}  (nginx SSL → dispatcher → publish)"
  for d in $CUSTOM_DOMAINS; do info "  $(site_url "$d")"; done
  echo ""
  info "${BOLD}Direct${RESET}"
  info "  Author      ${AUTHOR_URL}   (${AEM_ADMIN_USER} / see AEM_ADMIN_PASSWORD)"
  info "  Publish     ${PUBLISH_URL}"
  info "  Dispatcher  ${DISPATCHER_URL}"
  echo ""
  info "${BOLD}Test page${RESET}  SMOKE_PATH=${SMOKE_PATH}"
  info "  $(site_url "$FIRST_DOMAIN")${SMOKE_PATH}"
  info "  ${DISPATCHER_URL}${SMOKE_PATH}"
  echo ""
  info "Change any of these in .env — then: ${CYAN}make urls${RESET}"
  echo ""
}

# probe <label> <accepted-codes-regex> <shown-command> <curl args...>
probe() {
  local label="$1" ok_re="$2" shown="$3"; shift 3
  local code; code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$@" 2>/dev/null || true)"
  echo -e "  ${BOLD}${label}${RESET}"
  echo -e "    ${CYAN}\$ ${shown}${RESET}"
  if [[ "$code" =~ ^(${ok_re})$ ]]; then
    ok "HTTP ${code}"
  else
    echo -e "  ${RED}✘${RESET} HTTP ${code:-000}"; ERRORS=$((ERRORS+1))
  fi
}

cmd_smoke() {
  step "Smoke test — SMOKE_PATH=${SMOKE_PATH}"
  local w='-s -o /dev/null -w "%{http_code}\n"'

  probe "Author is up" "200" \
    "curl ${w} ${AUTHOR_URL}${AEM_LOGIN_PATH}" \
    "${AUTHOR_URL}${AEM_LOGIN_PATH}"

  probe "Publish serves the page" "200" \
    "curl ${w} -u ${AUTH_SHOWN} ${PUBLISH_URL}${SMOKE_PATH}" \
    -u "${AEM_ADMIN_USER}:${AEM_ADMIN_PASSWORD}" "${PUBLISH_URL}${SMOKE_PATH}"

  probe "Dispatcher → Publish" "200" \
    "curl ${w} ${DISPATCHER_URL}${SMOKE_PATH}" \
    "${DISPATCHER_URL}${SMOKE_PATH}"

  probe "Dispatcher as ${FIRST_DOMAIN} (Host header, as nginx sends it)" "200" \
    "curl ${w} -H \"Host: ${FIRST_DOMAIN}\" ${DISPATCHER_URL}${SMOKE_PATH}" \
    -H "Host: ${FIRST_DOMAIN}" "${DISPATCHER_URL}${SMOKE_PATH}"
  local vh; vh="$(curl -sI -m 15 -H "Host: ${FIRST_DOMAIN}" "${DISPATCHER_URL}${SMOKE_PATH}" 2>/dev/null \
                   | grep -i '^x-vhost' | tr -d '\r')"
  [[ -n "$vh" ]] && info "  ${vh}   (dispatcher vhost that answered)"

  for d in $CUSTOM_DOMAINS; do
    local u; u="$(site_url "$d")${SMOKE_PATH}"
    # No -k: a 200 here also proves the certificate is trusted
    probe "Site ${d} (SSL → dispatcher → publish)" "200" "curl ${w} ${u}" "$u"
  done

  echo ""
  if (( ERRORS == 0 )); then
    echo -e "  ${GREEN}${BOLD}All hops return 200 for ${SMOKE_PATH}.${RESET}"
  else
    echo -e "  ${RED}${BOLD}${ERRORS} check(s) failed.${RESET} Tips:"
    info "• 404 everywhere → SMOKE_PATH content not installed (make wknd) or wrong path in .env"
    info "• 000 on a site only → cert not trusted or hosts entry missing (make health)"
    info "• 502/503 via dispatcher → Publish not reachable (make health)"
  fi
  echo ""
  (( ERRORS == 0 ))
}

case "${1:-urls}" in
  urls)  cmd_urls ;;
  smoke) cmd_smoke ;;
  *) fail "Usage: $0 [urls|smoke]" ;;
esac
