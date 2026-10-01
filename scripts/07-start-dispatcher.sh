#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 07-start-dispatcher.sh [start|stop]
# Run the AEM Dispatcher container (docker compose service: dispatcher)
#   host :${DISPATCHER_PORT} → container :80 → host.docker.internal:${AEM_PUBLISH_PORT}
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

case "${1:-start}" in
  start)
    step "Starting AEM Dispatcher"
    require_docker
    [[ -f "$DISPATCHER_IMAGE_FILE" || -n "${DISPATCHER_IMAGE:-}" ]] \
      || fail "Dispatcher image unknown. Run: make dispatcher"
    [[ -n "$(ls -A "$DISPATCHER_SRC_DIR" 2>/dev/null)" ]] \
      || fail "$(rel "$DISPATCHER_SRC_DIR") is empty. Run: make dispatcher"

    if port_open "$DISPATCHER_PORT" && ! docker ps --format '{{.Names}}' | grep -qx aem-dispatcher; then
      fail "Port ${DISPATCHER_PORT} is used by another process. Change DISPATCHER_PORT in .env."
    fi

    compose up -d dispatcher
    ok "Dispatcher on ${CYAN}${DISPATCHER_URL}${RESET} → publish :${AEM_PUBLISH_PORT}"
    info "Logs: ${CYAN}make logs-dispatcher${RESET}"
    echo "" ;;
  stop)
    step "Stopping AEM Dispatcher"
    compose stop dispatcher 2>/dev/null || true
    compose rm -f dispatcher >/dev/null 2>&1 || true
    ok "Dispatcher stopped." ;;
  *) fail "Usage: $0 [start|stop]" ;;
esac
