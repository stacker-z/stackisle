#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 02-create-author-publish.sh
# Copy the quickstart jar into author/ and publish/ and unpack
# crx-quickstart/ for each. Never overwrites an existing instance.
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

step "Creating AEM Author and Publish instances"

JAR="$(quickstart_jar)"
[[ -n "$JAR" ]] || fail "Quickstart jar not found. Run: make sdk"

create_instance() {  # create_instance <name> <dir> <jar-path>
  local name="$1" dir="$2" target="$3" pid

  pid="$(find_java_pid "$target")"
  if [[ -n "$pid" ]]; then
    ok "${name} already running (PID ${pid}) — skipping creation (jar + crx-quickstart untouched)."
    return
  fi

  mkdir -p "$dir"

  if [[ -f "$target" ]]; then
    ok "${name} jar exists: ${CYAN}$(rel "$target")${RESET}"
  else
    cp "$JAR" "$target"
    ok "${name} jar created: ${CYAN}$(rel "$target")${RESET}"
  fi

  if [[ -d "$dir/crx-quickstart/app" || -d "$dir/crx-quickstart/launchpad" ]]; then
    ok "${name} crx-quickstart already unpacked — skipping."
  else
    info "Unpacking ${name} crx-quickstart..."
    (cd "$dir" && java -jar "$(basename "$target")" -unpack >/dev/null)
    ok "${name} unpacked."
  fi
}

create_instance "Author"  "$AUTHOR_DIR"  "$(author_jar)"
create_instance "Publish" "$PUBLISH_DIR" "$(publish_jar)"

echo ""
info "Run modes: author=${CYAN}${AUTHOR_RUNMODE}${RESET}  publish=${CYAN}${PUBLISH_RUNMODE}${RESET}"
echo ""
