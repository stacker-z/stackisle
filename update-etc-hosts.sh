#!/bin/bash
# ─────────────────────────────────────────────────────────────
# update-etc-hosts.sh [add|remove]
# Map every domain in CUSTOM_DOMAINS to HOSTS_IP (both from .env, default 127.0.0.1).
# Lines are tagged "# stackisle" so they can be removed cleanly.
# mac/linux: uses sudo. Windows (Git Bash): run the shell as Administrator.
# HOSTS_FILE (per OS) comes from scripts/lib/common.sh.
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/scripts/lib/common.sh"

TAG="# stackisle"

has_entry() {
  grep -qE "^[[:space:]]*${HOSTS_IP_RE}([[:space:]]+[^[:space:]#]+)*[[:space:]]+${1//./\\.}([[:space:]]|#|$)" "$HOSTS_FILE"
}

flush_dns() {
  case "$OS" in
    mac)     as_root dscacheutil -flushcache; as_root killall -HUP mDNSResponder 2>/dev/null || true ;;
    linux)   command -v resolvectl &>/dev/null && as_root resolvectl flush-caches 2>/dev/null || true ;;
    windows) ipconfig //flushdns >/dev/null 2>&1 || true ;;
  esac
}

case "${1:-add}" in
  add)
    step "Updating ${HOSTS_FILE}"
    CHANGED=0
    for d in $CUSTOM_DOMAINS; do
      if has_entry "$d"; then
        ok "${d} already mapped — skipping."
      else
        printf '%s\t%s\t%s\n' "$HOSTS_IP" "$d" "$TAG" | as_root tee -a "$HOSTS_FILE" >/dev/null
        ok "Added ${HOSTS_IP} ${CYAN}${d}${RESET}"
        CHANGED=1
      fi
    done
    (( CHANGED )) && flush_dns && ok "DNS cache flushed."
    ;;
  remove)
    step "Removing stackisle entries from ${HOSTS_FILE}"
    if ! grep -q "${TAG}\$" "$HOSTS_FILE" 2>/dev/null; then
      ok "No stackisle entries found."
    else
      TMP="$(mktemp)"
      grep -v "${TAG}\$" "$HOSTS_FILE" > "$TMP" || true
      # Safety: never write an empty hosts file
      [[ -s "$TMP" ]] || { rm -f "$TMP"; fail "Refusing to write an empty ${HOSTS_FILE}."; }
      as_root cp "$HOSTS_FILE" "${HOSTS_FILE}.stackisle.bak"
      as_root cp "$TMP" "$HOSTS_FILE"; rm -f "$TMP"
      flush_dns
      ok "Removed. Backup: ${HOSTS_FILE}.stackisle.bak"
    fi
    ;;
  *) fail "Usage: $0 [add|remove]" ;;
esac
echo ""
