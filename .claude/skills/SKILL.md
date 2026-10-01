---
name: stackisle
description: >
  Expert skill for the AEMaaCS local developer environment in this repository.
  Trigger this skill whenever the user mentions: running or debugging the local
  AEM setup, any script in scripts/ (00 through 09), the Makefile targets,
  AEM Author or Publish not starting or stopping, Dispatcher issues, nginx SSL proxy,
  docker-compose for AEM, SDK zip extraction (SDK_DIR), SSL certs (INSTALL_DIR/certs),
  mkcert, localhost:9999, custom https domains, run modes (author/publish/local), Java
  version errors (Java 21), prereq installers for mac/linux/windows, the Magento test
  stack, or any request to extend or modify scripts. Also trigger for AEM architecture
  questions: OSGi, Sling models, HTL, dispatcher config, vhost/farm files, cache rules.
  When in doubt, use this skill — it has the full picture of how this specific project works.
---

# AEM Local Dev Skill

> **Working agreement:** the user runs every command. Guide one step at a time
> (what it does, how to check, how to undo), edit scripts/docs, and hand over
> exact commands to run — never execute them yourself. When continuing on
> another machine, read `docs/session-handoff.md` first. See `CLAUDE.md`.

You are an expert in this project's cross-platform AEMaaCS local environment.
You know every numbered script in `scripts/`, the Makefile targets, the real
Adobe SDK file naming conventions, the two-container dispatcher+nginx
architecture, and the exact flow from `make` to a healthy
`http://localhost:9999` endpoint (dispatcher → publish), and the nginx SSL proxy
serving the portless domains from `CUSTOM_DOMAINS`, e.g. dev-local-www-brand.com,
dev-local-www-shop.brand.com, dev-local-www-b2b.brand.com, dev-local-www-new.brand.com.

## Project entry points

```bash
make              # Full flow: env → prereq → setup (01-05 + hosts) → start (06-08) → wait (09)
make help         # All targets, grouped
make stop         # Stop nginx, dispatcher, AEM
make restart      # stop + start
make health       # One-shot check of every hop (make wait = poll until healthy)
make clean        # Remove generated certs / nginx conf / image ref (keeps AEM + SDK)
make uninstall    # Revert everything make created (containers, images, hosts, AEM repos) — keeps SDK zip, .env

# Individual steps when something fails:
make prereq       # 00
make sdk          # 01 + 02   (make sdk-unpack / make instances)
make certs        # 03        (FORCE=1 make certs to regenerate)
make dispatcher   # 04        (make dispatcher-validate)
make nginx        # 05        (make reload-nginx after editing domains)
make hosts        # update-etc-hosts.sh add
make start-aem | start-dispatcher | start-nginx     # 06 | 07 | 08
make logs-author | logs-publish | logs-dispatcher | logs-nginx
```

## Quick health check (ask the user to run these before diagnosing anything)

```bash
make health       # Author, Publish, containers, dispatcher, every https domain, hosts, cert SANs
bash scripts/06-start-aem.sh status   # real java PIDs (adopts instances started by hand)
make paths        # where everything is (SDK_DIR / INSTALL_DIR)
java -version     # must be >= JAVA_REQUIRED (21 for SDK 2026.x), or set JAVA_HOME in .env
ls sdk/aem-sdk*.zip   # (SDK_DIR)
docker ps --filter name=aem-dispatcher --filter name=aem-nginx
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/
curl -sk -o /dev/null -w "%{http_code}\n" https://dev-local-www-brand.com/
```

## Script responsibilities

| Script | What it does |
|--------|-------------|
| `00-check-prereq.sh` | Validates Java ≥ `JAVA_REQUIRED` (21), Docker, tools, SDK zip, writable paths |
| `01-unpack-sdk.sh` | Finds `SDK_DIR/aem-sdk*.zip`, extracts versioned folder, locates quickstart jar |
| `02-create-author-publish.sh` | Copies quickstart jar → `INSTALL_DIR/author` and `/publish`, unpacks crx-quickstart |
| `03-create-cert.sh` | `INSTALL_DIR/certs/server.crt`+`.key`, SANs = all `CUSTOM_DOMAINS` (mkcert, else openssl) |
| `04-install-dispatcher.sh` | Extracts dispatcher tools → `SDK_DIR/dispatcher-sdk-X.Y.Z/`, seeds `INSTALL_DIR/dispatcher/src`, loads image → `INSTALL_DIR/dispatcher/docker/image.env` |
| `05-create-nginx-config.sh` | Writes `INSTALL_DIR/nginx/conf.d/<domain>.conf` (container paths, → `aem-dispatcher:80`) |
| `06-start-aem.sh` | `start\|stop\|status [author\|publish]`. PID in `<inst>/aem.pid`, valid only if it is `java … -jar aem-<inst>-p<port>.jar` (stale PIDs dropped, running instances adopted). Start fails with the log tail if Java exits. Stop = SIGTERM + wait until exit, no timeout, never `kill -9` |
| `07-start-dispatcher.sh` | `start\|stop` dispatcher container (compose service `dispatcher`) |
| `08-start-nginx.sh` | `start\|stop\|reload` nginx SSL container (compose service `nginx`) |
| `09-health-check.sh` | Checks every hop; `--wait` polls until healthy or `HEALTH_TIMEOUT` |
| `lib/common.sh` | Sourced by all scripts: .env, defaults, derived paths, SDK globs, `port_open`, `compose()` |
| `install-wknd.sh` | `make wknd` / `make start-aem WKND=1`: latest (or pinned) WKND "all" package from GitHub → Package Manager API on Author + Publish; waits for readiness without timeout; skips if installed |
| `uninstall.sh` | `make uninstall`: graceful AEM stop (aborts if still running), containers/images/volume, hosts, generated files |
| `magento/magento.sh` | Magento **test** stack — on hold, untested, not in make (see `docs/session-handoff.md`) |

## SDK file naming — critical patterns

```bash
# SDK_DIR (from .env, default ./sdk) holds the zip — glob, never hardcode:
SDK_ZIP=$(find -L "$SDK_DIR" -maxdepth 1 -name "aem-sdk*.zip" | sort | tail -n 1)

# Zip extracts into a versioned subfolder inside SDK_DIR:
SDK_UNPACKED=$(find -L "$SDK_DIR" -maxdepth 1 -type d -name "aem-sdk-*" | sort | tail -n 1)

# Quickstart jar is inside that subfolder:
QUICKSTART_JAR=$(find -L "$SDK_UNPACKED" -maxdepth 1 -name "aem-sdk-quickstart-*.jar" | head -n 1)

# Dispatcher shell installer is also inside that subfolder:
DISPATCHER_SHELL=$(find -L "$SDK_UNPACKED" -maxdepth 1 -name "aem-sdk-dispatcher-tools-*-unix.sh" | head -n 1)

# 04 runs it (--nox11 --quiet) inside SDK_DIR → SDK_DIR/dispatcher-sdk-X.Y.Z/:
DISP_SDK_DIR=$(find -L "$SDK_DIR" -maxdepth 1 -type d -name "dispatcher-sdk-*" | sort | tail -n 1)

# All of the above are functions in scripts/lib/common.sh:
#   sdk_zip  sdk_dir  quickstart_jar  dispatcher_tools_sh  dispatcher_sdk_dir

# docker_run.sh is inside that:
DOCKER_RUN_SH=$(find "$DISP_SDK_DIR" -maxdepth 2 -name "docker_run.sh" | head -n 1)
```

## Dispatcher + nginx architecture

```
Browser → https://dev-local-www-brand.com 
           [nginx container]
             cert:   INSTALL_DIR/certs/server.crt   (→ /etc/nginx/certs in container)
             config: INSTALL_DIR/nginx/conf.d/      (→ /etc/nginx/conf.d)
             → http://aem-dispatcher:80  (host view: http://localhost:9999)
                [AEM Dispatcher container]
                  config: INSTALL_DIR/dispatcher/src/  (→ /mnt/dev/src)
                  → http://host.docker.internal:4503
                     http://localhost:4503 AEM Publish (local Java process)
```

Both containers are defined in `docker-compose.yml` on the `aem-local-net` network
(`aem-nginx`, `aem-dispatcher`). nginx proxies to `http://aem-dispatcher:80` — the
same container that the host sees as `http://localhost:9999`.

## Platform-specific prereqs

```bash
# macOS
bash prereq/mac/install-prereq.sh

# Linux
bash prereq/linux/install-prereq.sh

# Windows (PowerShell as Admin)
powershell -File prereq/windows/install-prereq.ps1
```

## Run modes

| Instance | Jar | Flags |
|----------|-----|-------|
| Author | `INSTALL_DIR/author/aem-author-p4502.jar` | `-r author,local -p 4502` |
| Publish | `INSTALL_DIR/publish/aem-publish-p4503.jar` | `-r publish,local -p 4503` |

Run modes, ports and JVM opts come from `.env` (`AUTHOR_RUNMODE`, `PUBLISH_RUNMODE`,
`AEM_JVM_OPTS`). Java 21 (`JAVA_REQUIRED`); never add `-XX:MaxPermSize`.

## When modifying any script in scripts/

1. Read the script first: `cat scripts/NN-name.sh`
2. Check if a change affects other platforms — update prereq installers too
3. Keep scripts independently runnable (not dependent on previous script state where possible)
4. All generated files go under `INSTALL_DIR` via the derived variables (`CERTS_DIR`, `NGINX_CONF_DIR`, `DISPATCHER_*`) — never literal paths, never the project root
5. Source `scripts/lib/common.sh` — don't re-implement .env loading, globs or colours
6. Don't run it yourself — give the user the command (`bash -x scripts/NN-name.sh` for debug output) and wait for the pasted result
7. macOS: bash 3.2 (no bash-4 features), no `/proc` (use `ps -ww`), no `ss`/`getent`/GNU `ls --time-style`
8. Update the Makefile target if the script's inputs/outputs change
9. New stacks (Magento, k8s, ...) → `mk/<stack>.mk`, auto-included by the Makefile

## Reference docs — read before answering

| File | Load when |
|------|-----------|
| `references/aem-concepts.md` | AEM architecture, run modes, OSGi, Sling, HTL |
| `references/dispatcher-config.md` | vhost, farm, cache rules, rewrites |
| `references/troubleshooting.md` | Any error, service not starting, Docker issues |
| `references/script-guide.md` | Understanding or modifying scripts in `scripts/` |
