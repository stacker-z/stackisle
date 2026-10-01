#!/bin/bash
# ─────────────────────────────────────────────────────────────
# 06-start-aem.sh [start|stop|status] [author|publish|all]
# Run AEM Author + Publish as background Java processes.
#   PID  → ${AUTHOR_DIR|PUBLISH_DIR}/aem.pid
#   log  → ${AUTHOR_DIR|PUBLISH_DIR}/crx-quickstart/logs/stdout.log
# ─────────────────────────────────────────────────────────────

set -e
source "$(dirname "$0")/lib/common.sh"

ACTION="${1:-start}"
WHICH="${2:-all}"

# instance: <name> <dir> <jar> <port> <debug-port> <runmode>
instance_args() {
  case "$1" in
    author)  echo "Author $AUTHOR_DIR $(author_jar) $AEM_AUTHOR_PORT $AEM_AUTHOR_DEBUG_PORT $AUTHOR_RUNMODE" ;;
    publish) echo "Publish $PUBLISH_DIR $(publish_jar) $AEM_PUBLISH_PORT $AEM_PUBLISH_DEBUG_PORT $PUBLISH_RUNMODE" ;;
  esac
}

# pid_alive <pidfile> <jar> — true only if the PID is alive AND is a java process
# running exactly this jar. PIDs get reused after a crash/reboot; without this
# check a stale aem.pid could skip a start or make `stop` kill an unrelated process.
pid_alive() {
  [[ -f "$1" ]] || return 1
  local pid args; pid="$(cat "$1" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  args="$(proc_args "$pid")"
  [[ -z "$args" ]] && return 0                          # can't read args (Git Bash): trust kill -0
  [[ "$args" == *java* && "$args" == *"-jar ${2##*/}"* ]]
}

# Full command line of a PID. /proc is exact on Linux; `ps -ww` = unlimited
# width elsewhere (plain `ps` truncates long JVM command lines when piped).
proc_args() {
  if [[ -r "/proc/$1/cmdline" ]]; then tr '\0' ' ' < "/proc/$1/cmdline"
  else ps -ww -p "$1" -o args= 2>/dev/null; fi
}

# PID of the java process running exactly this jar (never shells/editors/tail
# that merely mention the file name)
find_java_pid() {
  local jre="${1##*/}"; jre="${jre//./\\.}"
  pgrep -f "^[^ ]*java .*-jar ${jre}( |$)" 2>/dev/null | head -n 1 || true
}

# Make <pidfile> point at the real java process: drop a stale PID and adopt a
# running instance (started by hand, or by an older version of this script).
sync_pid() {
  local pidf="$1" jar="$2" pid
  pid_alive "$pidf" "$jar" && return 0
  [[ -f "$pidf" ]] && { info "Removing stale $(rel "$pidf") (PID $(cat "$pidf" 2>/dev/null) is not this AEM instance)"; rm -f "$pidf"; }
  pid="$(find_java_pid "$jar")"
  if [[ -n "$pid" ]]; then
    echo "$pid" > "$pidf"
    info "Found running $(basename "$jar") (PID ${pid}) — recorded in $(rel "$pidf")"
  fi
  return 0
}

start_one() {
  read -r name dir jar port dport runmode <<<"$(instance_args "$1")"
  local pidf="$dir/aem.pid" log="$dir/crx-quickstart/logs/stdout.log"

  sync_pid "$pidf" "$jar"
  if pid_alive "$pidf" "$jar"; then
    warn "${name} already running (PID $(cat "$pidf")) — skipping."
    return
  fi
  if port_open "$port"; then
    warn "Port ${port} already answers but not from this ${name} — skipping."
    info "Check what owns it: ${CYAN}ss -ltnp | grep :${port}${RESET}   (mac: lsof -i :${port})"
    return
  fi
  [[ -f "$jar" ]] || fail "$(rel "$jar") not found. Run: make sdk"

  mkdir -p "$(dirname "$log")"
  # Only the java command is backgrounded, so $! is the java PID itself.
  # (With `cd … && nohup java … &` the whole list is backgrounded and $!
  #  would be a wrapper bash subshell — status/stop would track the wrong process.)
  (
    cd "$dir" || exit 1
    # shellcheck disable=SC2086
    nohup java ${AEM_JVM_OPTS} \
      -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=127.0.0.1:${dport} \
      -jar "$(basename "$jar")" -r "${runmode}" -p "${port}" -nofork -nobrowser \
      > "crx-quickstart/logs/stdout.log" 2>&1 &
    echo $! > aem.pid
  )

  # Quickstart exits within seconds on fatal problems (wrong Java version,
  # port clash, bad options) — don't report success for a dead process.
  sleep 5
  if ! pid_alive "$pidf" "$jar"; then
    rm -f "$pidf"
    echo -e "  ${RED}✘ ${name} exited right after start. Last lines of $(rel "$log"):${RESET}"
    tail -n 15 "$log" | sed 's/^/      /'
    fail "${name} failed to start."
  fi
  ok "${name} starting on ${CYAN}http://${LOCAL_HOSTNAME}:${port}${RESET} (debug 127.0.0.1:${dport}, run modes ${runmode}, PID $(cat "$pidf"))"
  info "log: ${CYAN}$(rel "$log")${RESET}"
}

stop_one() {
  read -r name dir jar port _ _ <<<"$(instance_args "$1")"
  local pidf="$dir/aem.pid" pid=""
  sync_pid "$pidf" "$jar"
  pid_alive "$pidf" "$jar" && pid="$(cat "$pidf")"
  if [[ -z "$pid" ]]; then
    ok "${name} not running."
    rm -f "$pidf"; return
  fi
  # Graceful shutdown only. SIGTERM runs the JVM shutdown hooks: OSGi stops
  # bundles and Oak closes the repository and flushes indexes (the same thing
  # crx-quickstart/bin/stop does). NEVER kill -9: interrupting that can corrupt
  # the repository/indexes. On timeout we stop waiting and report — AEM keeps
  # shutting down on its own.
  info "Stopping ${name} gracefully (PID ${pid}, SIGTERM) — waiting until the repository has closed ..."
  info "(Ctrl+C only stops waiting — AEM keeps shutting down cleanly)"
  kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  trap 'echo ""; warn "Stopped waiting — ${name} (PID ${pid}) is still shutting down on its own. Check: bash scripts/06-start-aem.sh status"; exit 130' INT
  while kill -0 "$pid" 2>/dev/null; do
    (( AEM_STOP_TIMEOUT > 0 && waited >= AEM_STOP_TIMEOUT )) && break
    sleep 5; waited=$((waited + 5))
    (( waited % 30 == 0 )) && info "… still shutting down (${waited}s) — log: $(rel "$dir")/crx-quickstart/logs/error.log"
  done
  trap - INT
  if kill -0 "$pid" 2>/dev/null; then
    echo -e "  ${RED}✘ ${name} still shutting down after ${AEM_STOP_TIMEOUT}s — NOT force-killed.${RESET}"
    info "Watch it finish:  ${CYAN}tail -f $(rel "$dir")/crx-quickstart/logs/error.log${RESET}"
    info "Check again:      ${CYAN}bash scripts/06-start-aem.sh status${RESET}"
    info "No time limit: set ${CYAN}AEM_STOP_TIMEOUT=0${RESET} in .env (the default)"
    return 1
  fi
  rm -f "$pidf"
  ok "${name} stopped cleanly (${waited}s)."
}

status_one() {
  read -r name dir jar port _ _ <<<"$(instance_args "$1")"
  local pidf="$dir/aem.pid"
  sync_pid "$pidf" "$jar"
  if pid_alive "$pidf" "$jar"; then
    if port_open "$port"; then ok "${name} running (PID $(cat "$pidf")), listening on :${port}"
    else warn "${name} process up (PID $(cat "$pidf")) — still booting, :${port} not open yet"; fi
  elif port_open "$port"; then warn "Port ${port} answers, but not from this ${name} (no matching java process)"
  else echo -e "  ${RED}✘${RESET} ${name} not running"; fi
}

case "$WHICH" in all) TARGETS="author publish" ;; author|publish) TARGETS="$WHICH" ;;
  *) fail "Unknown instance '$WHICH' (author|publish|all)" ;; esac

case "$ACTION" in
  start)
    step "Starting AEM"
    command -v java &>/dev/null || fail "Java not found. Run: make prereq"
    [[ "$(java_major)" -ge "$JAVA_REQUIRED" ]] || fail "Java ${JAVA_REQUIRED}+ required (found $(java_major))."
    for t in $TARGETS; do start_one "$t"; done
    echo ""
    info "${YELLOW}First boot takes 5-10 min. Check with: ${BOLD}make health${RESET}"
    echo "" ;;
  stop)
    step "Stopping AEM"
    rc=0
    for t in $TARGETS; do stop_one "$t" || rc=1; done   # always attempt every instance
    # Non-zero if anything is still shutting down, so `make restart` / `make uninstall`
    # do not start again or delete repositories underneath a running AEM.
    exit "$rc" ;;
  status) for t in $TARGETS; do status_one "$t"; done ;;
  *) fail "Usage: $0 [start|stop|status] [author|publish|all]" ;;
esac
