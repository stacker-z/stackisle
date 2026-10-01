# AEM Local Dev — Project Context

> Claude reads this on every session. Follow every convention here without
> being asked. Read the relevant reference file before answering AEM questions.

## Working agreement (applies on every machine)

- **The user runs every command.** Claude guides step by step, explains what each
  step does, how to check it and how to undo it, and edits scripts/docs — but does
  not execute setup, test or verification commands (not even in a scratch copy).
  When something must be checked, give the exact command and what to look for,
  then wait for the pasted output.
- One step at a time; flag anything that changes the system (sudo, hosts file,
  Docker images, ports) before the user runs it.
- **Continuing from another machine?** Read `docs/session-handoff.md` first —
  it holds the current state, decisions and open items.

## What this project is

A cross-platform, one-command local developer environment for **Adobe Experience
Manager as a Cloud Service (AEMaaCS)**. The entry point is `make` (or individual
numbered scripts in `scripts/`). It sets up and starts:

| Service     | URL                                  | Notes                                |
|-------------|--------------------------------------|--------------------------------------|
| Site        | https://dev-local-www-brand.com      | nginx SSL → Dispatcher → Publish     |
| Site        | https://dev-local-www-shop.brand.com | nginx SSL → Dispatcher → Publish     |
| Site        | https://dev-local-www-b2b.brand.com  | nginx SSL → Dispatcher → Publish     |
| Site        | https://dev-local-www-new.brand.com  | nginx SSL → Dispatcher → Publish     |
| AEM Author  | http://localhost:4502                | Run mode: `author,local`             |
| AEM Publish | http://localhost:4503                | Run mode: `publish,local`            |
| Dispatcher  | http://localhost:9999                | AEM Dispatcher container → Publish   |

Site URLs never carry a port — nginx (Docker) owns 443/80 and hides the
dispatcher and AEM Publish behind it. One site row per domain in `CUSTOM_DOMAINS`.

You could have one or more custom domains or subdomains.

Default credentials: **admin / admin**

## Project layout

```
aem-local-dev/
├── CLAUDE.md                    # This file — Claude's project context
├── Makefile                     # Primary entry point: `make`, `make help`, `make stop`, etc.
├── mk/                          # Makefile extensions — every mk/*.mk is auto-included (new stacks)
├── docker-compose.yml           # Docker services: aem-dispatcher + aem-nginx on aem-local-net
├── update-etc-hosts.sh          # Maps CUSTOM_DOMAINS → 127.0.0.1 (add|remove)
├── .env.example                 # Copy to .env and fill in before running
│
├── scripts/                     # Numbered setup steps — run in order
│   ├── lib/common.sh            # Shared: .env loading, defaults, SDK globs, compose() — source it
│   ├── 00-check-prereq.sh       # Validate Java 21+, Docker, tools, SDK zip, writable paths
│   ├── 01-unpack-sdk.sh         # Extract SDK_DIR/aem-sdk*.zip → SDK_DIR/aem-sdk-<ver>/
│   ├── 02-create-author-publish.sh  # Quickstart jar → INSTALL_DIR/author, /publish + unpack
│   ├── 03-create-cert.sh        # INSTALL_DIR/certs/server.crt+key (mkcert, else openssl)
│   ├── 04-install-dispatcher.sh # Dispatcher tools, seed INSTALL_DIR/dispatcher/src, load image
│   ├── 05-create-nginx-config.sh    # INSTALL_DIR/nginx/conf.d/<domain>.conf
│   ├── 06-start-aem.sh          # start|stop|status [author|publish] (graceful stop, PID check)
│   ├── 07-start-dispatcher.sh   # start|stop dispatcher container
│   ├── 08-start-nginx.sh        # start|stop|reload nginx SSL container
│   ├── 09-health-check.sh       # Check every hop; --wait polls until healthy
│   ├── uninstall.sh             # `make uninstall` — revert everything (keeps zip, .env)
│   ├── install-wknd.sh          # `make wknd` / `start-aem WKND=1` — optional WKND sample site
│   ├── set-paths.sh             # `make set-paths` — write SDK_DIR / INSTALL_DIR into .env
│   └── magento/                 # Magento TEST stack — ON HOLD, untested, not wired into make
│                                #   (see docs/session-handoff.md → open items)
│
├── prereq/                      # Platform-specific prerequisite installers
│   ├── mac/
│   │   ├── install-brew.sh
│   │   └── install-prereq.sh
│   ├── linux/
│   │   └── install-prereq.sh
│   └── windows/
│       ├── install-choco.ps1
│       └── install-prereq.ps1
│
├── sdk/                         # SDK_DIR and INSTALL_DIR (both "./sdk" by default) — all gitignored
│   ├── .gitkeep
│   ├── aem-sdk-<ver>.zip        # ← you place this (SDK_DIR)
│   ├── aem-sdk-<ver>/           # unpacked SDK: quickstart jar + dispatcher tools (SDK_DIR)
│   ├── dispatcher-sdk-X.Y.Z/    # extracted dispatcher tools: validator, docker_run.sh, lib/ (SDK_DIR)
│   ├── author/                  # author jar + crx-quickstart/ (INSTALL_DIR)
│   ├── publish/                 # publish jar + crx-quickstart/ (INSTALL_DIR)
│   ├── certs/                   # server.crt + server.key (INSTALL_DIR)
│   ├── nginx/conf.d/            # generated nginx server blocks (INSTALL_DIR)
│   └── dispatcher/              # (INSTALL_DIR)
│       ├── src/                 # vhost + farm config — edit these (seeded from SDK)
│       ├── docker/image.env     # dispatcher image + SDK path, read by compose
│       ├── logs/                # saved by `make logs-dispatcher`
│       └── cache/               # created by Adobe's validator (make dispatcher-validate)
│
│   Nothing is created at the project root: no root author/ publish/ certs/
│   nginx/ dispatcher/ cache/ — those were the old layout.
│
├── docs/
│   ├── setup-guide.md           # Step-by-step guide (steps 1–12, checks, undo, pitfalls)
│   └── session-handoff.md       # Current state, decisions, open items, macOS checklist
│
└── .claude/
    └── skills/
        ├── SKILL.md             # Claude Code skill definition
        └── references/          # Detailed reference docs (loaded on demand)
            ├── aem-concepts.md
            ├── dispatcher-config.md
            ├── script-guide.md
            └── troubleshooting.md
```

## Entry points

```bash
# Full setup — preferred
make

# List every target
make help

# Individual steps (if something fails mid-way)
make prereq      # 00
make sdk         # 01 + 02
make certs       # 03  (FORCE=1 to regenerate)
make dispatcher  # 04
make nginx       # 05
make hosts       # /etc/hosts
make start       # 06 + 07 + 08
make health      # 09  (make wait = poll until healthy)

# Stop / restart
make stop                          # nginx → dispatcher → AEM (AEM graceful, waits)
make stop-aem                      # AEM only; bash scripts/06-start-aem.sh stop publish = one instance
make restart

# Other
make set-paths INSTALL_DIR=/opt/aem   # write SDK_DIR / INSTALL_DIR into .env (either or both)
make paths                         # show the resolved layout (read-only)
make dispatcher-validate           # Adobe validator (phases 1–3)
make urls                          # every URL, built from .env
make smoke                         # test SMOKE_PATH on every hop (prints the curl commands)
make wknd                          # optional: WKND sample site on Author + Publish
make start-aem WKND=1              # start AEM, wait until ready, then install WKND
make uninstall                     # revert everything (asks)
```

## SDK file naming conventions

```
# Place the SDK zip in sdk/ before running:
sdk/aem-sdk-2024.3.15168.20240313T183424Z-240200.zip

# 01-unpack-sdk.sh extracts it — zip unpacks into a versioned folder:
sdk/aem-sdk-2025.7.21772.20250730T182007Z-250600/
  ├── aem-sdk-quickstart-*.jar            ← cloned to author/ and publish/
  └── aem-sdk-dispatcher-tools-*-unix.sh  ← self-extracts to sdk/dispatcher-sdk-X.Y.Z/

# Always glob — never hardcode version strings:
find sdk/ -maxdepth 1 -type d -name "aem-sdk-*" | sort | tail -n 1
```

## Dispatcher architecture

```
Browser → https://dev-local-www-brand.com
           [nginx container  aem-nginx]
             cert:   INSTALL_DIR/certs/server.crt     (→ /etc/nginx/certs in the container)
             config: INSTALL_DIR/nginx/conf.d/        (→ /etc/nginx/conf.d)
             → http://aem-dispatcher:80   (same container as host http://localhost:9999)
                [AEM Dispatcher container  aem-dispatcher]
                  config: INSTALL_DIR/dispatcher/src/ (→ /mnt/dev/src, applied by Adobe's
                          import_sdk_config.sh hook — compose mirrors bin/docker_run.sh)
                  → http://host.docker.internal:4503
                     http://localhost:4503 AEM Publish (local Java process)
```

Inside the nginx container `localhost` is nginx itself, so nginx reaches the
dispatcher by its compose service name on `aem-local-net`; port 9999 is the
dispatcher's host-side mapping for direct browser/curl access.

## Platform support

| Platform | Prereq installer | Notes |
|----------|-----------------|-------|
| macOS | `prereq/mac/install-prereq.sh` | Homebrew-based |
| Linux | `prereq/linux/install-prereq.sh` | apt/dnf-based |
| Windows | `prereq/windows/install-prereq.ps1` | Chocolatey-based |

## Conventions Claude must follow

- **Docker/docker daemon** required.
- **Java 21+** required (`JAVA_REQUIRED=21` in `.env`). AEM SDK 2026.x quickstart refuses to
  start on 17 ("requires a Java Specification 21 VM"). Never suggest a lower version; if a
  future SDK demands more, raise `JAVA_REQUIRED` — scripts and installers follow it.
- **SDK zip lives in `SDK_DIR`** (default `sdk/`) — not the project root. Pattern: `aem-sdk*.zip`.
- **Never hardcode SDK version strings** — always use globs.
- **Scripts are numbered** (`00`–`09`) and must stay in order. Never renumber.
- **Makefile is the primary interface** — suggest `make <target>` not raw `bash scripts/`.
- **Cross-platform** — changes to any script must consider mac/linux/windows equivalents.
- **Dispatcher tools** self-extract via `-unix.sh`; output dir is `sdk/dispatcher-sdk-X.Y.Z/`.
- **Scripts source `scripts/lib/common.sh`** for .env, defaults, globs and `compose()` — never duplicate that logic.
- **Never force-kill AEM** (`kill -9`) — stop is SIGTERM, then wait until the JVM has exited (no
  fixed timeout; `AEM_STOP_TIMEOUT=0`) so the Oak repository and indexes close cleanly. Never
  introduce arbitrary wait limits. Nothing may delete or restart a repository while its JVM runs.
- **JVM opts** — never add `-XX:MaxPermSize` (JVM refuses to start). Debug ports bind to
  `127.0.0.1` only — never `*` (an open JDWP port allows remote code execution).
- **Only two paths are configurable** in `.env`; everything else derives from them
  (`scripts/lib/common.sh`). Scripts use the derived variables, never literal paths.
  `make paths` prints the layout.
  ```
  SDK_DIR="./sdk"       # aem-sdk*.zip + unpacked aem-sdk-*/ + dispatcher-sdk-*/
  INSTALL_DIR="./sdk"   # author/ publish/ dispatcher/{src,docker,logs} certs/ nginx/conf.d/
  ```
- **Deletions are item-specific** — uninstall/clean remove named stackisle files, never whole
  configurable directories, and process matching must target the java command line only.
- **Config input file** for domains and necesary ports is `.env`. and cert name.
- **Nothing environment-specific is hardcoded** — hosts, IPs, ports, domains, test paths and
  credentials come from `.env` (defaults in `scripts/lib/common.sh`: `LOCAL_HOSTNAME`,
  `HOSTS_IP`, `*_PORT`, `CUSTOM_DOMAINS`, `SMOKE_PATH`, `AEM_LOGIN_PATH`, `AEM_ADMIN_*`,
  `WKND_*`). Scripts use the derived `AUTHOR_URL`, `PUBLISH_URL`, `DISPATCHER_URL`,
  `site_url <domain>`. In docs, prefer `make urls` / `make smoke` over hand-typed URLs.
  Fixed by design (not per-user): container names/ports inside Docker (`aem-dispatcher:80`,
  `host.docker.internal`) and the JDWP bind `127.0.0.1` (security).
- **Must verify all prerequiste installers** before running `make`.
- **Make** must be extendable to enhance and add more scripts as name suggest stakisle.
  New stacks go in `mk/<stack>.mk` (auto-included; see `mk/README.md`).


## Reference docs for Claude

Read before answering — do not guess:

| File | Load when |
|------|-----------|
| `.claude/skills/references/aem-concepts.md` | AEM architecture, run modes, OSGi, Sling, HTL |
| `.claude/skills/references/dispatcher-config.md` | Editing vhost, farm, cache, rewrites |
| `.claude/skills/references/troubleshooting.md` | Any error or service not starting |
| `.claude/skills/references/script-guide.md` | Understanding or modifying any script in `scripts/` |
