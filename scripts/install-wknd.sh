#!/bin/bash
# ─────────────────────────────────────────────────────────────
# scripts/install-wknd.sh [author|publish|all]        (make wknd)
# Optional: install Adobe's WKND sample site ("all" package) on AEM.
#
#   make wknd                    install on Author + Publish (AEM must be running)
#   make start-aem WKND=1        start AEM, wait until ready, then install
#   make WKND=1                  full setup incl. WKND
#   FORCE=1 make wknd            reinstall even if this version is installed
#
# Package: github.com/adobe/aem-guides-wknd releases → aem-guides-wknd.all-<ver>.zip
#   latest by default, or WKND_VERSION in .env. Never hardcoded.
#   Downloaded once to SDK_DIR/packages/ (reused offline).
# Install: AEM Package Manager HTTP API (/crx/packmgr/service.jsp), admin creds
#   from .env (AEM_ADMIN_USER / AEM_ADMIN_PASSWORD, default admin/admin).
# Waits for AEM readiness WITHOUT a timeout (progress shown; Ctrl+C stops waiting only).
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

# All from .env (defaults in common.sh / here): WKND_REPO, WKND_PACKAGE, WKND_VERSION,
# WKND_TARGETS, AEM_ADMIN_USER/PASSWORD, AUTHOR_URL/PUBLISH_URL, SMOKE_PATH
: "${WKND_VERSION:=}"
: "${WKND_TARGETS:=author publish}"
: "${WKND_PACKAGE:=aem-guides-wknd.all}"

PKG_NAME="$WKND_PACKAGE"
PKG_DIR="$SDK_DIR/packages"
GH_API="https://api.github.com/repos/${WKND_REPO}/releases"

case "${1:-all}" in
  all)            TARGETS="$WKND_TARGETS" ;;
  author|publish) TARGETS="$1" ;;
  *) fail "Usage: $0 [author|publish|all]" ;;
esac

aem_url()  { [[ "$1" == author ]] && echo "$AUTHOR_URL" || echo "$PUBLISH_URL"; }
aem_name() { [[ "$1" == author ]] && echo "Author" || echo "Publish"; }
acurl()    { curl -s -u "${AEM_ADMIN_USER}:${AEM_ADMIN_PASSWORD}" "$@"; }

# ── 1. Resolve + download the package ────────────────────────
# Prints the URL of the "all" zip (not the ".classic" one for AEM 6.5)
resolve_url() {
  local json pattern
  if [[ -n "$WKND_VERSION" ]]; then
    json="$(curl -fsSL "${GH_API}?per_page=100" 2>/dev/null)" || return 1
    pattern="${PKG_NAME//./\\.}-${WKND_VERSION//./\\.}\\.zip"
  else
    json="$(curl -fsSL "${GH_API}/latest" 2>/dev/null)" || return 1
    pattern="${PKG_NAME//./\\.}-[0-9][0-9.]*[0-9]\\.zip"
  fi
  echo "$json" | grep -oE "\"browser_download_url\": *\"[^\"]*/${pattern}\"" \
    | head -n 1 | sed -E 's/.*"(https[^"]+)"/\1/'
}

fetch_package() {
  mkdir -p "$PKG_DIR"
  local url zip
  url="$(resolve_url || true)"
  if [[ -n "$url" ]]; then
    zip="$PKG_DIR/$(basename "$url")"
    if [[ -f "$zip" ]]; then
      ok "Package already downloaded: $(rel "$zip")" >&2
    else
      info "Downloading ${CYAN}${url}${RESET}" >&2
      curl -fL --progress-bar -o "$zip.part" "$url" >&2 && mv "$zip.part" "$zip"
      ok "Downloaded $(rel "$zip")" >&2
    fi
  else
    # Offline / GitHub API unavailable → newest (or pinned) local zip
    if [[ -n "$WKND_VERSION" ]]; then zip="$PKG_DIR/${PKG_NAME}-${WKND_VERSION}.zip"
    else zip="$(find "$PKG_DIR" -maxdepth 1 -name "${PKG_NAME}-*.zip" ! -name '*.classic.zip' 2>/dev/null | sort | tail -n 1)"; fi
    [[ -f "$zip" ]] || fail "Could not find the WKND package on GitHub (offline or rate-limited?) and none in $(rel "$PKG_DIR").
       Download ${PKG_NAME}-<version>.zip from https://github.com/${WKND_REPO}/releases into $(rel "$PKG_DIR")"
    warn "GitHub not reachable — using local $(rel "$zip")" >&2
  fi
  echo "$zip"
}

# ── 2. Readiness (no timeout) ────────────────────────────────
# bundles.json "s":[total,active,fragment,resolved,installed] — ready when every
# bundle is active or a fragment.
bundles_stable() {
  local s total active frag
  s="$(acurl "$1/system/console/bundles.json" | grep -oE '"s":\[[0-9,]+\]' | head -n 1 | tr -dc '0-9,')"
  [[ -n "$s" ]] || return 1
  IFS=, read -r total active frag _ _ <<<"$s"
  [[ "$total" -gt 0 && $((active + frag)) -eq "$total" ]]
}

wait_ready() {  # wait_ready <target> <what>
  local url name; url="$(aem_url "$1")"; name="$(aem_name "$1")"
  port_open "${url##*:}" || fail "${name} is not running (${url}). Start it: make start-aem  (or: make start-aem WKND=1)"
  local waited=0
  trap 'echo ""; warn "Stopped waiting — nothing was installed on ${name}."; exit 130' INT
  until [[ "$(http_code "${url}${AEM_LOGIN_PATH}")" == 200 ]] && bundles_stable "$url"; do
    (( waited % 30 == 0 )) && info "Waiting for ${name} $2 (${waited}s) — first boot can take 5-10 min, Ctrl+C stops waiting"
    sleep 5; waited=$((waited + 5))
  done
  trap - INT
  ok "${name} ready ($2)."
}

# ── 3. Install ───────────────────────────────────────────────
is_installed() {  # is_installed <url> <zip-basename> — uploaded AND unpacked
  acurl "$1/crx/packmgr/service.jsp?cmd=ls" | tr -d '\n' | sed 's#</package>#|#g' | tr '|' '\n' \
    | grep "<downloadName>$2</downloadName>" | grep -qE '<lastUnpacked>[^<]+'
}

install_on() {  # install_on <target> <zip>
  local t="$1" zip="$2" url name out
  url="$(aem_url "$t")"; name="$(aem_name "$t")"
  step "WKND → ${name} (${url})"
  wait_ready "$t" "for install"

  if [[ "${FORCE:-0}" != "1" ]] && is_installed "$url" "$(basename "$zip")"; then
    ok "$(basename "$zip") already installed on ${name} — skipping (FORCE=1 to reinstall)."
    return
  fi

  info "Uploading + installing $(basename "$zip") (several minutes; no timeout) ..."
  out="$(acurl -F "file=@${zip}" -F "name=${PKG_NAME}" -F "force=true" -F "install=true" \
           "$url/crx/packmgr/service.jsp")"
  if ! grep -q '<status code="200">' <<<"$out"; then
    echo "$out" | tail -n 20 | sed 's/^/      /'
    fail "Package Manager reported an error on ${name} (see above)."
  fi
  ok "Package installed on ${name}."

  # The "all" package installs embedded packages and bundles — let them settle
  wait_ready "$t" "after install"
  local code; code="$(http_code -u "${AEM_ADMIN_USER}:${AEM_ADMIN_PASSWORD}" "${url}${SMOKE_PATH}")"
  [[ "$code" == 200 ]] && ok "${url}${SMOKE_PATH} → HTTP 200" \
                       || warn "${url}${SMOKE_PATH} → HTTP ${code} (may need a minute more; SMOKE_PATH in .env)"
}

# ── main ─────────────────────────────────────────────────────
step "WKND sample site"
ZIP="$(fetch_package)"
for t in $TARGETS; do install_on "$t" "$ZIP"; done

echo ""
info "Author : ${CYAN}${AUTHOR_URL}/sites.html${RESET}"
info "Publish: ${CYAN}${PUBLISH_URL}${SMOKE_PATH}${RESET}"
for d in $CUSTOM_DOMAINS; do info "Site   : ${CYAN}$(site_url "$d")${SMOKE_PATH}${RESET}"; done
info "Test every hop: ${CYAN}make smoke${RESET}"
echo ""
