#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 04-install-dispatcher.sh
# 1. Self-extract aem-sdk-dispatcher-tools-*-unix.sh → ${SDK_DIR}/dispatcher-sdk-X.Y.Z/
# 2. Seed ${DISPATCHER_SRC_DIR} from the SDK default config (only if empty and
#    DISPATCHER_SRC_DIR is not a custom override — those must already exist)
# 3. Discover/load the dispatcher-publish image that ships with the SDK, and
#    pin it + DISPATCHER_SDK_DIR + DISPATCHER_SRC_DIR into
#    ${DISPATCHER_DIR}/docker/image.env for docker compose
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

step "Installing AEM Dispatcher tools"

# ── 1. Extract dispatcher tools ──────────────────────────────
DSDK="$(dispatcher_sdk_dir)"
if [[ -n "$DSDK" ]]; then
  ok "Dispatcher SDK already extracted: ${CYAN}$(rel "$DSDK")${RESET}"
else
  DT="$(dispatcher_tools_sh)"
  [[ -n "$DT" ]] || fail "aem-sdk-dispatcher-tools-*-unix.sh not found. Run: make sdk"
  info "Extracting ${CYAN}$(rel "$DT")${RESET} into ${CYAN}$(rel "$SDK_DIR")${RESET} ..."
  # --nox11: never try to open a separate terminal window (IDE/SSH/CI safe)
  (cd "$SDK_DIR" && bash "$DT" --nox11 --quiet >/dev/null)
  DSDK="$(dispatcher_sdk_dir)"
  [[ -n "$DSDK" ]] || fail "Extraction did not produce $(rel "$SDK_DIR")/dispatcher-sdk-*/"
  ok "Extracted: ${CYAN}$(rel "$DSDK")${RESET}"
fi

# ── 2. Seed dispatcher config ────────────────────────────────
mkdir -p "$DISPATCHER_LOG_DIR" "$(dirname "$DISPATCHER_IMAGE_FILE")"
SRC_REL="$(rel "$DISPATCHER_SRC_DIR")"
if [[ "$DISPATCHER_SRC_DIR" != "$DISPATCHER_DIR/src" ]]; then
  # Custom override (DISPATCHER_SRC_DIR set in .env) — must already exist;
  # never created, seeded, or modified here.
  [[ -d "$DISPATCHER_SRC_DIR" ]] \
    || fail "DISPATCHER_SRC_DIR override ${SRC_REL} does not exist. Create it, or clear DISPATCHER_SRC_DIR in .env to use the default."
  ok "${SRC_REL} (custom DISPATCHER_SRC_DIR) — using as-is, never seeded or modified."
elif [[ -n "$(ls -A "$DISPATCHER_SRC_DIR" 2>/dev/null)" ]]; then
  ok "${SRC_REL} already has config — leaving it untouched."
elif [[ -d "$DSDK/src" ]]; then
  mkdir -p "$DISPATCHER_SRC_DIR"
  cp -R "$DSDK/src/." "$DISPATCHER_SRC_DIR/"
  ok "Seeded ${CYAN}${SRC_REL}${RESET} from the SDK default — customise vhosts/farms here."
else
  mkdir -p "$DISPATCHER_SRC_DIR"
  warn "No default src/ in $(rel "$DSDK") — add your dispatcher config to ${SRC_REL}."
fi

# ── 3. Dispatcher image ──────────────────────────────────────
step "Resolving dispatcher image"

IMAGE="${DISPATCHER_IMAGE:-}"

if [[ -z "$IMAGE" ]]; then
  require_docker
  case "$(docker info --format '{{.Architecture}}' 2>/dev/null)" in
    aarch64|arm64) ARCH=arm64 ;;
    *)             ARCH=amd64 ;;
  esac
  TARBALL="$(find "$DSDK" -maxdepth 2 -name "*dispatcher-publish*${ARCH}*.tar*" | sort | tail -n 1)"
  if [[ -n "$TARBALL" ]]; then
    info "Loading ${CYAN}${TARBALL}${RESET} ..."
    IMAGE="$(docker load -i "$TARBALL" | sed -n 's/^Loaded image: //p' | tail -n 1)"
  fi
fi

if [[ -z "$IMAGE" ]]; then
  RUN_SH="$(find "$DSDK" -maxdepth 2 -name docker_run.sh | head -n 1)"
  if [[ -n "$RUN_SH" ]]; then
    IMAGE="$(grep -oE 'adobe/[a-z-]+/dispatcher-publish:[A-Za-z0-9._-]+' "$RUN_SH" | head -n 1)"
  fi
fi

[[ -n "$IMAGE" ]] || fail "Could not determine dispatcher image. Set DISPATCHER_IMAGE in .env."

[[ -f "$DSDK/lib/import_sdk_config.sh" ]] \
  || fail "$(rel "$DSDK")/lib/import_sdk_config.sh missing — this SDK version is not supported."

# Read by compose(): image + SDK folder (its lib/ is mounted into the container)
# + src folder (vhost/farm config, default or custom override — see step 2)
cat > "$DISPATCHER_IMAGE_FILE" <<EOF
DISPATCHER_IMAGE=${IMAGE}
DISPATCHER_SDK_DIR=${DSDK}
DISPATCHER_SRC_DIR=${DISPATCHER_SRC_DIR}
EOF
ok "Dispatcher image: ${CYAN}${IMAGE}${RESET} (saved to $(rel "$DISPATCHER_IMAGE_FILE"))"

echo ""
info "Custom domains are passed to the dispatcher via the Host header from nginx."
info "Make sure your vhost ServerAlias / farm /virtualhosts match: ${CYAN}${CUSTOM_DOMAINS}${RESET}"
info "Validate config any time with: ${CYAN}make dispatcher-validate${RESET}"
echo ""
