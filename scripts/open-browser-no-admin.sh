#!/bin/bash
# ─────────────────────────────────────────────────────────────
# scripts/open-browser-no-admin.sh          (make browser-no-admin)
# Admin-free alternative to `make hosts`: opens CUSTOM_DOMAINS in a
# throwaway Chrome/Edge profile using --host-resolver-rules to map
# each domain to HOSTS_IP, entirely inside the browser process.
# Nothing outside INSTALL_DIR is touched — no sudo, no /etc/hosts.
#
# Chrome and Edge both support --host-resolver-rules (same engine).
# Safari (WebKit) has no equivalent flag — this technique cannot
# support it; Safari users need `make hosts` instead.
#
# Scope: only the window this script launches sees the mapping.
# Other browsers, browser windows/profiles, and tools like curl
# still need `make hosts` (or an explicit --resolve / --connect-to).
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

# Prints "path|name" of the first Chrome/Edge binary found, nothing if none.
find_browser() {
  local c p n
  case "$OS" in
    mac)
      for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome|Chrome" \
               "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge|Edge"; do
        p="${c%%|*}"; n="${c##*|}"
        [[ -x "$p" ]] && { echo "$p|$n"; return; }
      done
      ;;
    linux)
      for c in "google-chrome|Chrome" "google-chrome-stable|Chrome" \
               "chromium|Chromium" "chromium-browser|Chromium" \
               "microsoft-edge|Edge" "microsoft-edge-stable|Edge"; do
        p="${c%%|*}"; n="${c##*|}"
        command -v "$p" &>/dev/null && { echo "$(command -v "$p")|$n"; return; }
      done
      ;;
    windows)
      for c in "/c/Program Files/Google/Chrome/Application/chrome.exe|Chrome" \
               "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe|Chrome" \
               "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe|Edge" \
               "/c/Program Files/Microsoft/Edge/Application/msedge.exe|Edge"; do
        p="${c%%|*}"; n="${c##*|}"
        [[ -x "$p" ]] && { echo "$p|$n"; return; }
      done
      ;;
  esac
}

RESULT="$(find_browser)"
[[ -n "$RESULT" ]] || fail "Chrome or Edge not found.
       This path needs Chrome or Edge specifically (--host-resolver-rules).
       Safari has no equivalent flag and can't use this path at all.
       Fallback: make hosts"
BROWSER_BIN="${RESULT%%|*}"
BROWSER_NAME="${RESULT##*|}"

RULES=""
for d in $CUSTOM_DOMAINS; do
  RULES+="${RULES:+,}MAP ${d} ${HOSTS_IP}"
done

PROFILE_DIR="${INSTALL_DIR}/browser-no-admin"
mkdir -p "$PROFILE_DIR"

URLS=()
for d in $CUSTOM_DOMAINS; do URLS+=("$(site_url "$d")"); done

step "Opening a throwaway ${BROWSER_NAME} profile (no /etc/hosts, no sudo)"
info "Profile:  $(rel "$PROFILE_DIR")  (separate from your normal ${BROWSER_NAME} — no shared cookies/logins)"
info "Resolver: ${RULES}"
info "Scope:    only this window resolves these domains — other tools still need ${CYAN}make hosts${RESET}"
info "Safari:   not supported by this path (no --host-resolver-rules equivalent) — use ${CYAN}make hosts${RESET}"
echo ""

"$BROWSER_BIN" \
  --user-data-dir="$PROFILE_DIR" \
  --no-first-run \
  --no-default-browser-check \
  --new-window \
  --host-resolver-rules="$RULES" \
  "${URLS[@]}" \
  >/dev/null 2>&1 &
disown

ok "Launched. Undo/cleanup: rm -rf $(rel "$PROFILE_DIR")"
echo ""
