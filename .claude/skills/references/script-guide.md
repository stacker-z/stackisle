# Script Guide

> Loaded by the stackisle skill when the user wants to understand, modify, or
> debug a script in `scripts/`, `update-etc-hosts.sh`, or the `Makefile`.

---

## Flow

```
make  →  env → prereq(00) → sdk(01,02) → certs(03) → dispatcher(04) → nginx(05)
      →  hosts → start-aem(06) → start-dispatcher(07) → start-nginx(08) → wait(09)
```

`.NOTPARALLEL` keeps prerequisites in order. Every script is also runnable on
its own (`bash scripts/NN-*.sh`) from any directory.

---

## scripts/lib/common.sh — sourced by everything

| Provides | Notes |
|----------|-------|
| `cd $ROOT_DIR` | Scripts work from any cwd |
| `.env` loading | `set -a; source .env` — quoted values OK. Empty `JAVA_HOME` is unset; a set one is prepended to `PATH` |
| Defaults | `CUSTOM_DOMAINS`, ports, run modes, `AEM_JVM_OPTS`, `DISPATCHER_PORT=9999`, `CERT_NAME=server`, `JAVA_REQUIRED=21`, `HEALTH_TIMEOUT=900`, `AEM_STOP_TIMEOUT=0` (no limit — stop waits until AEM has exited), `SDK_DIR=./sdk`, `INSTALL_DIR=./sdk` |
| `JAVA_HOME` | Blank → `java` on PATH; set → prepended to `PATH`. No auto-detection — `00` fails with a hint if the version is below `JAVA_REQUIRED` |
| Paths | Only `SDK_DIR` and `INSTALL_DIR` come from `.env` (made absolute by `abs_path`: relative → project root, `~` → `$HOME`). Derived, not configurable: `AUTHOR_DIR` `PUBLISH_DIR` `DISPATCHER_DIR` `DISPATCHER_SRC_DIR` `CERTS_DIR` `NGINX_CONF_DIR` (all under `INSTALL_DIR`). Exported for compose; `$INSTALL_PATH_VARS` lists them |
| `rel <path>` | Shortens a path for messages (relative when inside the project) |
| URLs | From `.env` only: `LOCAL_HOSTNAME`, `HOSTS_IP` (+ `HOSTS_IP_RE`), `SMOKE_PATH`, `AEM_LOGIN_PATH`, `AEM_ADMIN_USER/PASSWORD`, `WKND_REPO`. Derived: `AUTHOR_URL`, `PUBLISH_URL`, `DISPATCHER_URL`, `HTTPS_SUFFIX`, `site_url <domain>`, `FIRST_DOMAIN`. `HOSTS_FILE` per OS. **Never hardcode a host, IP, port or path in a script** |
| `CERT_FILE` / `KEY_FILE` | `${CERTS_DIR}/${CERT_NAME}.crt` / `.key` |
| `DISPATCHER_IMAGE_FILE` / `DISPATCHER_LOG_DIR` / `DISPATCHER_CACHE_DIR` | `${DISPATCHER_DIR}/docker/image.env` / `…/logs` / `…/cache` |
| `HOST_OS` | `uname` output, passed to the dispatcher container (as `docker_run.sh` does) |
| `ok` `warn` `info` `fail` `step` | Output helpers; `fail` exits 1 |
| `OS` / `as_root` | `mac`/`linux`/`windows`; `as_root` = sudo except Git Bash/root |
| `port_open <port> [host]` | Pure-bash `/dev/tcp` probe (no lsof) |
| `http_code <curl args>` | Prints status, `000` if unreachable |
| `java_major` | Handles `1.8` and `21.0.x` formats || `sdk_zip` `sdk_dir` `quickstart_jar` `dispatcher_tools_sh` `dispatcher_sdk_dir` | Globs under `SDK_DIR` (`find -L`, follows symlinks) — never hardcode versions |
| `author_jar` `publish_jar` | `${AUTHOR_DIR}/aem-author-p<port>.jar` etc. |
| `require_docker` | Fails if CLI missing or daemon unreachable |
| `compose ...` | `docker compose` with `${DISPATCHER_DIR}/docker/image.env` exported |

---

## 00-check-prereq.sh
Verifies the platform installer exists, then curl, unzip, openssl, Docker +
daemon + compose v2, Java ≥ `JAVA_REQUIRED`; mkcert optional. On anything
missing it offers to run `prereq/<os>/install-prereq.sh` (interactive only) and
exits 1. Then checks `.env`, the SDK zip in `SDK_DIR` (or an unpacked SDK), and that
every install path (or its nearest existing parent) is writable.

## 01-unpack-sdk.sh
Newest `SDK_DIR/aem-sdk*.zip` → `SDK_DIR/<zip-basename>/`. Flattens an inner folder
if the zip has one, so quickstart jar and dispatcher tools sit at depth 1.
Skips if the jar is already there.

## 02-create-author-publish.sh
Copies the quickstart jar to `INSTALL_DIR/author/aem-author-p4502.jar` and
`INSTALL_DIR/publish/aem-publish-p4503.jar` (ports from `.env`), then `java -jar … -unpack`.
Never overwrites an existing jar or unpacked `crx-quickstart/`.

## 03-create-cert.sh
SANs = `CUSTOM_DOMAINS` + `localhost` + `127.0.0.1`.
- mkcert present → `mkcert -cert-file INSTALL_DIR/certs/server.crt -key-file …/server.key …` (trusted)
- else → `openssl req -x509 … -days 825` with a SAN config (browser warning)

Writes `INSTALL_DIR/certs/.server.sans`; regenerates only when domains change or `FORCE=1`.

## 04-install-dispatcher.sh
1. Runs `aem-sdk-dispatcher-tools-*-unix.sh` inside `SDK_DIR` → `SDK_DIR/dispatcher-sdk-X.Y.Z/`
2. Seeds `INSTALL_DIR/dispatcher/src/` from the SDK's `src/` **only if empty**
3. Image: `DISPATCHER_IMAGE` from `.env`, else `docker load` of the SDK's
   `*dispatcher-publish*<arch>*.tar*`, else grep of `docker_run.sh`.
   Saved with `DISPATCHER_SDK_DIR` to `${INSTALL_DIR}/dispatcher/docker/image.env`, consumed by `compose()`.
4. Extractor is run with `--nox11 --quiet` (otherwise it may try to spawn an xterm when
   stdin is not a TTY). Its post-extract `bin/setup` only symlinks the right `validator` binary.

## 05-create-nginx-config.sh
Deletes previously generated files (marker line), then writes:
- `INSTALL_DIR/nginx/conf.d/00-http-redirect.conf` — :80 → https
- `INSTALL_DIR/nginx/conf.d/<domain>.conf` — `listen 443 ssl`, cert `/etc/nginx/certs/server.crt`,
  `proxy_pass http://aem-dispatcher:80`, `Host $host`, `X-Forwarded-Proto https`

Paths are **container** paths — `docker-compose.yml` mounts `${INSTALL_DIR}/certs` and
`${INSTALL_DIR}/nginx/conf.d`; each file carries `# host: …` comments. Other stacks may add
their own files there with their own marker (e.g. Magento's `zz-magento-*.conf`) — 05 only
deletes files carrying its own marker.

## 06-start-aem.sh `[start|stop|status] [author|publish|all]`
```bash
nohup java $AEM_JVM_OPTS -agentlib:jdwp=…address=127.0.0.1:<debug> \   # debug port: localhost only
  -jar aem-author-p4502.jar -r author,local -p 4502 -nofork -nobrowser \
  > crx-quickstart/logs/stdout.log 2>&1 &
```
Only `nohup java …` is backgrounded inside the `( cd … )` subshell, so `$!` is the java PID
(backgrounding `cd … && nohup java … &` would record a wrapper bash PID instead).
PID → `<instance>/aem.pid`. A PID only counts if `/proc/<pid>/cmdline` (or `ps -ww`) shows
`java … -jar aem-<inst>-p<port>.jar`. `sync_pid` drops stale PIDs and adopts a running instance
(started by hand or by an older script) via `pgrep -f`. Start waits 5s and fails with the log tail
if java died. `stop` is **graceful only**: SIGTERM (JVM shutdown hooks → OSGi stops bundles, Oak
closes the repository and flushes indexes — same as `crx-quickstart/bin/stop`), then waits **until
the JVM has exited** — no fixed limit by default (`AEM_STOP_TIMEOUT=0`), because shutdown time varies
with repository size, running reindexes and disk speed. Progress every 30s; Ctrl+C stops only the
waiting (trap), never AEM. It **never** sends SIGKILL — a hard kill mid-shutdown can corrupt the
repository/indexes. If a limit is set (CI) and reached, it exits non-zero, so `make restart` and
`make uninstall` stop instead of starting again or deleting repositories under a running AEM.

## 07-start-dispatcher.sh `[start|stop]`
Checks image + `INSTALL_DIR/dispatcher/src`, refuses if `DISPATCHER_PORT` is held by a
non-dispatcher process, then `compose up -d dispatcher`.
The compose service mirrors the SDK's `bin/docker_run.sh`: same env (`AEM_HOST`, `AEM_PORT`,
`HOST_OS`, `ENVIRONMENT_TYPE=dev`, lowercase log levels, `ENABLE_MANAGED_REWRITE_MAPS_FLAG`) and
same mounts — `src` → `/mnt/dev/src`, SDK `lib/` → `/usr/lib/dispatcher-sdk`, and
`lib/import_sdk_config.sh` → `/docker_entrypoint.d/zzz-import-sdk-config.sh`. **That hook is what
applies `/mnt/dev/src`; without it the container runs only its built-in defaults.** Cache lives
in the named volume `aem-dispatcher-cache`. `extra_hosts: host.docker.internal:host-gateway`
makes the Publish connection work on Linux.

## 08-start-nginx.sh `[start|stop|reload]`
Checks cert + conf, port 80/443 free, starts dispatcher (nginx resolves
`aem-dispatcher` at boot), runs `nginx -t` in a throwaway container, then
`compose up -d nginx`. `reload` = test + `nginx -s reload`.

## 09-health-check.sh `[--wait]`
Checks: Author login 200 · Publish reachable · both containers running ·
dispatcher `localhost:9999` answers (not 000/5xx) · every
`https://<domain>` via `curl --resolve` · hosts entries · cert covers every domain.
`--wait` repeats every 10s until green or `HEALTH_TIMEOUT`.

## uninstall.sh `[-y]`  (make uninstall)
1. Graceful AEM stop — **aborts** (removes nothing) if AEM is still shutting down.
2. Validator cache (via the dispatcher image if root-owned) — before images are removed.
3. `compose down --rmi all --volumes`, removes `aem-local-net`.
4. Hosts lines tagged `# stackisle` (Magento's `# stackisle-magento` untouched).
5. Instances, unpacked SDK, `server.crt/.key`, 05-marked nginx conf, image ref, dispatcher log.
6. `dispatcher/src` only if identical to the SDK default.

Deletes named items only, never whole configurable directories. Keeps the SDK zip,
`.env`, sources. Never removes system packages (prints how).

## install-wknd.sh `[author|publish|all]`  (make wknd · make start-aem WKND=1)
Optional WKND sample site. Resolves `aem-guides-wknd.all-<ver>.zip` via the GitHub releases
API (latest, or `WKND_VERSION`; never the `.classic` 6.5 package), downloads it once to
`SDK_DIR/packages/` (offline fallback: newest local zip). Per target in `WKND_TARGETS`:
`wait_ready` (login 200 + `bundles.json` `s[]` active+fragment == total, **no timeout**,
Ctrl+C trap) → skip if `service.jsp?cmd=ls` shows that `downloadName` with a `lastUnpacked`
date (unless `FORCE=1`) → `curl -F file=@… -F install=true …/crx/packmgr/service.jsp`, must
return `<status code="200">` → wait_ready again → check `/content/wknd/us/en.html`.
Uses `AEM_ADMIN_USER`/`AEM_ADMIN_PASSWORD` (default admin/admin).

## urls.sh `[urls|smoke]`  (make urls · make smoke)
`urls` prints every URL built from `.env`. `smoke` curls `SMOKE_PATH` through each hop:
Author login, Publish (admin auth), Dispatcher, Dispatcher with `Host: FIRST_DOMAIN` (shows
`X-Vhost`), and every site URL without `-k` (so a 200 also proves the cert is trusted). It prints
each exact curl (password masked) and exits non-zero if any hop isn't 200.

## set-paths.sh `<SDK_DIR> <INSTALL_DIR>`  (make set-paths)
`make set-paths SDK_DIR=… INSTALL_DIR=…` (either or both). The Makefile passes only
values given **on the command line** (`$(origin …)`), never ones inherited from the
shell environment. It rewrites the `NAME=` line in `.env` with awk + a temp file (no
`sed -i`, which differs between GNU and BSD), keeps trailing comments, and appends
the line if it's missing. Creates `.env` from the example if needed. Prints the new
layout and warns if an existing install or SDK zip stays in the old location.
Never moves files.

## update-etc-hosts.sh `[add|remove]`
Adds `127.0.0.1<TAB><domain><TAB># stackisle` per domain (exact-match check),
flushes DNS. `remove` deletes only tagged lines. Windows path:
`/c/Windows/System32/drivers/etc/hosts` (Git Bash as Administrator).

---

## Makefile

- Default goal `all`; `make help` groups targets by `##@ Section`.
- Does **not** `include .env` — scripts load it (avoids literal-quote bugs).
- `dispatcher-validate` runs Adobe's `validate.sh` from `INSTALL_DIR/dispatcher` because its
  `docker_run.sh` bind-mounts `${PWD}/cache`; the folder is pre-created as the user so Docker
  doesn't create it root-owned. `uninstall` removes it (via the dispatcher image if files are root-owned).
- Extension: `-include mk/*.mk`. Add `mk/<stack>.mk` with `##` comments; hook into
  the main flow with e.g. `all: magento-start`. See `mk/README.md`.
