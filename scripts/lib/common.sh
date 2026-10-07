#!/bin/bash
# ─────────────────────────────────────────────────────────────
# scripts/lib/common.sh
# Shared helpers sourced by every numbered script and the Makefile.
#   - cd to project root (scripts work from any cwd)
#   - load .env safely (quoted values OK)
#   - colours + ok/warn/info/fail/step
#   - OS detection, port checks, HTTP wait
#   - SDK globbing (never hardcode versions)
#   - docker compose wrapper
# ─────────────────────────────────────────────────────────────

# ── Project root ──────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

# ── Colours / output ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✔${RESET} $*"; }
warn() { echo -e "  ${YELLOW}!${RESET} ${YELLOW}$*${RESET}"; }
info() { echo -e "    $*"; }
fail() { echo -e "  ${RED}✘ $*${RESET}" >&2; exit 1; }
step() { echo ""; echo -e "  ${BOLD}$*${RESET}"; echo ""; }

# ── .env loading ─────────────────────────────────────────────
load_env() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
  fi
}
load_env

# Empty JAVA_HOME breaks some launchers; a set one should win over PATH.
if [[ -z "${JAVA_HOME:-}" ]]; then
  unset JAVA_HOME
elif [[ -x "$JAVA_HOME/bin/java" ]]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi

# ── Defaults (override any of these in .env) ─────────────────
: "${CUSTOM_DOMAINS:=dev-local-www-brand.com dev-local-www-shop.brand.com dev-local-www-b2b.brand.com dev-local-www-new.brand.com}"
: "${AEM_AUTHOR_PORT:=4502}"
: "${AEM_PUBLISH_PORT:=4503}"
: "${AEM_AUTHOR_DEBUG_PORT:=45045}"
: "${AEM_PUBLISH_DEBUG_PORT:=45046}"
: "${AUTHOR_RUNMODE:=author,local}"
: "${PUBLISH_RUNMODE:=publish,local}"
: "${AEM_JVM_OPTS:=-server -Xms1024m -Xmx4096m -Djava.awt.headless=true}"
: "${DISPATCHER_PORT:=9999}"
: "${NGINX_HTTP_PORT:=80}"
: "${NGINX_HTTPS_PORT:=443}"
: "${CERT_NAME:=server}"
# AEM SDK 2026.x quickstart refuses to start below Java 21 ("requires a Java Specification 21 VM")
: "${JAVA_REQUIRED:=21}"
: "${HEALTH_TIMEOUT:=900}"
# `stop` waits for a graceful AEM shutdown until the JVM has exited (never force-kills).
# 0 = no limit (default). Set seconds only for unattended use (e.g. CI) — on timeout
# stop just reports and exits non-zero; AEM keeps shutting down on its own.
: "${AEM_STOP_TIMEOUT:=0}"
: "${AEM_ADMIN_USER:=admin}"
: "${AEM_ADMIN_PASSWORD:=admin}"

# ── URLs — built only from .env values, never hardcoded in scripts ──
# LOCAL_HOSTNAME   how this machine reaches Author/Publish/Dispatcher
# SMOKE_PATH       page used for end-to-end checks (make smoke / health / wknd)
# AEM_LOGIN_PATH   page that answers 200 once AEM is up (readiness)
# HOSTS_IP         IP the CUSTOM_DOMAINS map to in the hosts file (and in the cert SANs)
: "${LOCAL_HOSTNAME:=localhost}"
: "${HOSTS_IP:=127.0.0.1}"
: "${SMOKE_PATH:=/content/wknd/us/en.html}"
: "${AEM_LOGIN_PATH:=/libs/granite/core/content/login.html}"
: "${WKND_REPO:=adobe/aem-guides-wknd}"
HOSTS_IP_RE="${HOSTS_IP//./\\.}"                          # for grep -E

AUTHOR_URL="http://${LOCAL_HOSTNAME}:${AEM_AUTHOR_PORT}"
PUBLISH_URL="http://${LOCAL_HOSTNAME}:${AEM_PUBLISH_PORT}"
DISPATCHER_URL="http://${LOCAL_HOSTNAME}:${DISPATCHER_PORT}"
# Port suffix only when nginx isn't on the standard port (URLs stay portless by default)
HTTPS_SUFFIX=""; [[ "$NGINX_HTTPS_PORT" != "443" ]] && HTTPS_SUFFIX=":${NGINX_HTTPS_PORT}"
site_url() { echo "https://${1}${HTTPS_SUFFIX}"; }        # site_url <domain>
FIRST_DOMAIN="${CUSTOM_DOMAINS%% *}"


# ── Install paths (override in .env) ─────────────────────────
# Relative paths resolve against the project root; ~ expands to $HOME.
abs_path() {
  local p="${1/#\~/$HOME}"
  while [[ "$p" == ./* ]]; do p="${p#./}"; done
  [[ "$p" == "." ]] && p=""
  if [[ "$p" == /* ]]; then echo "${p%/}"; else echo "${ROOT_DIR}${p:+/${p%/}}"; fi
}

# Two paths are always configurable — everything else derives from them:
#   SDK_DIR      aem-sdk*.zip, unpacked aem-sdk-*/ and dispatcher-sdk-*/
#   INSTALL_DIR  author/ publish/ dispatcher/{src,docker,logs,cache} certs/ nginx/conf.d/
: "${SDK_DIR:=./sdk}"
: "${INSTALL_DIR:=./sdk}"
SDK_DIR="$(abs_path "$SDK_DIR")"
INSTALL_DIR="$(abs_path "$INSTALL_DIR")"

AUTHOR_DIR="$INSTALL_DIR/author"                  # author jar + crx-quickstart
PUBLISH_DIR="$INSTALL_DIR/publish"                # publish jar + crx-quickstart
DISPATCHER_DIR="$INSTALL_DIR/dispatcher"
CERTS_DIR="$INSTALL_DIR/certs"                    # <CERT_NAME>.crt/.key
NGINX_CONF_DIR="$INSTALL_DIR/nginx/conf.d"        # generated nginx server blocks

# DISPATCHER_SRC_DIR: optional third override. Blank (default) → vhost/farm
# config lives at INSTALL_DIR/dispatcher/src, seeded from the SDK. Set it to
# point at an existing checkout's dispatcher/src instead (e.g. your own AEM
# project repo) — that directory must already exist; 04-install-dispatcher.sh
# never creates or seeds it, and uninstall.sh never deletes it.
if [[ -n "${DISPATCHER_SRC_DIR:-}" ]]; then
  DISPATCHER_SRC_DIR="$(abs_path "$DISPATCHER_SRC_DIR")"
else
  DISPATCHER_SRC_DIR="$DISPATCHER_DIR/src"
fi

# Host OS name passed to the dispatcher container (as the SDK's docker_run.sh does)
export HOST_OS="$(uname)"

# Exported so docker compose (via compose()) mounts the same paths
export SDK_DIR INSTALL_DIR AUTHOR_DIR PUBLISH_DIR DISPATCHER_DIR \
       DISPATCHER_SRC_DIR CERTS_DIR NGINX_CONF_DIR
INSTALL_PATH_VARS="SDK_DIR INSTALL_DIR AUTHOR_DIR PUBLISH_DIR DISPATCHER_SRC_DIR CERTS_DIR NGINX_CONF_DIR"

CERT_FILE="${CERTS_DIR}/${CERT_NAME}.crt"
KEY_FILE="${CERTS_DIR}/${CERT_NAME}.key"
DISPATCHER_IMAGE_FILE="${DISPATCHER_DIR}/docker/image.env"
DISPATCHER_LOG_DIR="${DISPATCHER_DIR}/logs"
# Adobe's validate.sh → docker_run.sh mounts ${PWD}/cache, so make runs it from DISPATCHER_DIR
DISPATCHER_CACHE_DIR="${DISPATCHER_DIR}/cache"

# Short form for messages: path relative to project root when inside it
rel() { local p="$1"; [[ "$p" == "$ROOT_DIR"/* ]] && echo "${p#"$ROOT_DIR"/}" || echo "$p"; }


# ── OS detection ─────────────────────────────────────────────
detect_os() {
  case "$OSTYPE" in
    darwin*)              echo "mac" ;;
    linux*)               echo "linux" ;;
    msys*|cygwin*|win32*) echo "windows" ;;
    *)                    echo "unknown" ;;
  esac
}
OS="$(detect_os)"

# System hosts file for this OS (used by update-etc-hosts.sh, health check, Magento)
HOSTS_FILE=/etc/hosts
[[ "$OS" == "windows" ]] && HOSTS_FILE=/c/Windows/System32/drivers/etc/hosts

# sudo is not available in Git Bash on Windows (run the shell as Admin instead)
as_root() {
  if [[ "$OS" == "windows" || "$(id -u 2>/dev/null)" == "0" ]]; then "$@"; else sudo "$@"; fi
}

# ── Ports / HTTP ─────────────────────────────────────────────
# Pure-bash TCP probe — no lsof/netstat needed (works on mac/linux/Git Bash)
port_open() {  # port_open <port> [host]  (host defaults to LOCAL_HOSTNAME from .env)
  (exec 3<>"/dev/tcp/${2:-$LOCAL_HOSTNAME}/$1") 2>/dev/null
}

# Prints the HTTP status code (000 when unreachable)
http_code() {
  curl -sk -o /dev/null -m 10 -w "%{http_code}" "$@" 2>/dev/null || true
}

# ── Java ─────────────────────────────────────────────────────
java_major() {
  local v
  v=$(java -version 2>&1 | awk -F '"' '/version/ {print $2; exit}')
  [[ "$v" == 1.* ]] && v="${v#1.}"
  echo "${v%%.*}"
}

# ── Process ──────────────────────────────────────────────────
# Full command line of a PID ("" if unreadable or the process is gone). /proc
# is exact on Linux; `ps -ww` = unlimited width elsewhere (plain `ps` truncates
# long JVM command lines when piped).
proc_args() {
  if [[ -r "/proc/$1/cmdline" ]]; then tr '\0' ' ' < "/proc/$1/cmdline"
  else ps -ww -p "$1" -o args= 2>/dev/null; fi
}

# PID of any running "java … -jar <jar's basename>" process, wherever it was
# started from — this project treats "is AEM Author/Publish running" as a
# machine-wide question (one instance per port), not tied to INSTALL_DIR.
# Shared by 02-create-author-publish.sh (skip creation/unpack against a live
# instance) and 06-start-aem.sh (skip start, adopt an orphaned PID that has
# no pidfile yet).
find_java_pid() {  # find_java_pid <jar-path>
  local jre="${1##*/}"; jre="${jre//./\\.}"
  pgrep -f "^[^ ]*java .*-jar ${jre}( |$)" 2>/dev/null | head -n 1 || true
}

# Working directory of a running PID ("" if unreadable or the process is
# gone). /proc is exact on Linux; lsof's "cwd" fd entry covers macOS (no /proc).
proc_cwd() {
  if [[ -r "/proc/$1/cwd" ]]; then readlink -f "/proc/$1/cwd" 2>/dev/null
  else command -v lsof &>/dev/null && lsof -p "$1" 2>/dev/null | awk '$4=="cwd"{print $NF; exit}'; fi
}

# instance_live_dir <jar-path> <configured-dir> — crx-quickstart/ lives in
# whatever directory the running instance's java process was actually
# started from, which may not be <configured-dir> (e.g. INSTALL_DIR changed
# since it started, or it was started by hand elsewhere). Falls back to
# <configured-dir> when the instance isn't running at all.
instance_live_dir() {
  local jar="$1" fallback="$2" pid cwd
  pid="$(find_java_pid "$jar")"
  if [[ -n "$pid" ]]; then
    cwd="$(proc_cwd "$pid")"
    [[ -n "$cwd" ]] && { echo "$cwd"; return; }
  fi
  echo "$fallback"
}

# ── SDK globbing — never hardcode version strings ────────────
sdk_zip()      { find -L "$SDK_DIR" -maxdepth 1 -type f -name "aem-sdk*.zip" 2>/dev/null | sort | tail -n 1; }
sdk_dir()      { find -L "$SDK_DIR" -maxdepth 1 -type d -name "aem-sdk-*" 2>/dev/null | sort | tail -n 1; }
quickstart_jar() {
  local d; d="$(sdk_dir)"; [[ -n "$d" ]] || return 0
  find -L "$d" -maxdepth 1 -name "aem-sdk-quickstart-*.jar" | sort | tail -n 1
}
dispatcher_tools_sh() {
  local d; d="$(sdk_dir)"; [[ -n "$d" ]] || return 0
  find -L "$d" -maxdepth 1 -name "aem-sdk-dispatcher-tools-*-unix.sh" | sort | tail -n 1
}
dispatcher_sdk_dir() { find -L "$SDK_DIR" -maxdepth 1 -type d -name "dispatcher-sdk-*" 2>/dev/null | sort | tail -n 1; }

author_jar()  { echo "${AUTHOR_DIR}/aem-author-p${AEM_AUTHOR_PORT}.jar"; }
publish_jar() { echo "${PUBLISH_DIR}/aem-publish-p${AEM_PUBLISH_PORT}.jar"; }

# ── Docker ───────────────────────────────────────────────────
require_docker() {
  command -v docker &>/dev/null || fail "Docker not found. Run: make install-prereq"
  docker info &>/dev/null      || fail "Docker daemon is not running. Start Docker and retry."
}

# docker compose with the dispatcher image discovered by 04-install-dispatcher.sh
compose() {
  if [[ -f "$DISPATCHER_IMAGE_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$DISPATCHER_IMAGE_FILE"; set +a
  fi
  docker compose -f "$ROOT_DIR/docker-compose.yml" --project-directory "$ROOT_DIR" "$@"
}
