# Stackisle — AEM Local Setup Guide (step by step)

A hands-on walkthrough of setting up the local AEMaaCS stack one step at a time:
what to run, what each step does, how to check it and how to undo it.

> Plain `make` runs steps 3–12 in one go. This guide runs them one at a time,
> so you can see and verify every piece.
>
> Written from a Linux run. A few check commands are Linux-only (`ss`, `getent`,
> `ls --time-style`, `apt`); for the macOS equivalents, see the table in
> [session-handoff.md](session-handoff.md#macos-test-checklist).
>
> **URLs, ports and the test page shown here are the `.env` defaults.** Scripts never
> hardcode them; they build every URL from `.env` (`LOCAL_HOSTNAME`, `*_PORT`,
> `CUSTOM_DOMAINS`, `HOSTS_IP`, `SMOKE_PATH`). Your actual values:
> - `make urls` prints every URL of your setup
> - `make smoke` tests every hop on `SMOKE_PATH` and prints the exact `curl` it ran

---

## What you end up with

```
Browser → https://dev-local-www-brand.com                 (no port — nginx owns 443/80)
  [Docker] aem-nginx        INSTALL_DIR/certs  +  INSTALL_DIR/nginx/conf.d
    → http://aem-dispatcher:80                           (same container as host http://localhost:9999)
      [Docker] aem-dispatcher   INSTALL_DIR/dispatcher/src
        → http://host.docker.internal:4503
          [Host] AEM Publish (Java 21)
[Host] AEM Author :4502 (Java 21)
```

| URL | What |
|---|---|
| https://dev-local-www-brand.com (and every other `CUSTOM_DOMAINS` entry) | Site through nginx SSL → dispatcher → Publish |
| http://localhost:4502 | AEM Author (admin / admin) |
| http://localhost:4503 | AEM Publish |
| http://localhost:9999 | Dispatcher, direct (no SSL) |

**Inside vs. outside containers.** The nginx config uses container paths
(`/etc/nginx/certs/server.crt`) and container names (`http://aem-dispatcher:80`).
`docker-compose.yml` maps `INSTALL_DIR/certs → /etc/nginx/certs`. Inside a
container, `localhost` means that container itself, so nginx reaches the
dispatcher by name on the Docker network `aem-local-net`.

---

## Paths — two variables decide everything

In `.env`:

```bash
SDK_DIR="./sdk"       # The path of the SDK container: aem-sdk*.zip + unpacked SDK
INSTALL_DIR="./sdk"   # The path you want to install
```

| Derived path | Contents |
|---|---|
| `SDK_DIR/aem-sdk-<ver>.zip` | the SDK zip — **you put it here** |
| `SDK_DIR/aem-sdk-<ver>/` | unpacked SDK (quickstart jar, dispatcher tools) |
| `SDK_DIR/dispatcher-sdk-X.Y.Z/` | extracted dispatcher tools (validator, `docker_run.sh`, `lib/`) |
| `INSTALL_DIR/author/`, `INSTALL_DIR/publish/` | AEM jar + `crx-quickstart/` (repository, logs, `aem.pid`) |
| `INSTALL_DIR/certs/` | `server.crt`, `server.key` |
| `INSTALL_DIR/nginx/conf.d/` | generated nginx server blocks |
| `INSTALL_DIR/dispatcher/src/` | dispatcher vhost/farm config (seeded from the SDK) |
| `INSTALL_DIR/dispatcher/docker/image.env` | dispatcher image + SDK path, read by compose |
| `INSTALL_DIR/dispatcher/cache/` | cache used by `make dispatcher-validate` |

Set them with a command, or edit `.env` by hand; the result is the same:

```bash
make set-paths INSTALL_DIR=/opt/aem                   # writes INSTALL_DIR into .env
make set-paths SDK_DIR=./sdk INSTALL_DIR=~/aem-local  # both at once
make paths                                            # read-only: show the resolved layout
```

Nothing is created in the project root. Changing a path doesn't move an existing
install; `set-paths` warns and lists the options (move the folders after `make stop`,
or `make uninstall` and reinstall).

> `sdk/` is gitignored — it holds GBs of repositories. That includes
> `sdk/dispatcher/src`: dispatcher changes made there are **not** version-controlled.

---

## Step 1 — Prerequisites

| Need | Linux | macOS | Windows |
|---|---|---|---|
| Java **21+** | `sudo apt install -y openjdk-21-jdk` | `brew install --cask temurin@21` | `choco install temurin21` |
| Docker + compose v2 | Docker Engine | Docker Desktop | Docker Desktop (WSL2) |
| Docker access | `sudo usermod -aG docker $USER`, then log out/in | automatic | automatic |
| curl, unzip, openssl, make | apt | built in | Git Bash + `choco install make` |
| mkcert (optional, trusted certs) | `sudo apt install -y mkcert libnss3-tools` | `brew install mkcert nss` | `choco install mkcert` |

`make install-prereq` runs the right installer (`prereq/<os>/`). On Windows, run
`prereq/windows/install-prereq.ps1` in an Admin PowerShell and then use Git Bash.

**Java version.** AEM SDK 2026.x refuses to start below Java 21:
`Quickstart requires a Java Specification 21 VM`. The minimum is `JAVA_REQUIRED=21`
in `.env`; checks and installers follow it. Point AEM at the right JDK without
changing your system default:

```bash
JAVA_HOME="/usr/lib/jvm/java-21-openjdk-arm64"   # .env — use -amd64 on Intel/AMD
```

**Docker group (Linux).** Group changes only apply to new logins. Until you log
out and back in, `docker ps` still says *permission denied*. `newgrp docker`
works for one terminal. Undo: `sudo gpasswd -d $USER docker`.

**mkcert.** `mkcert -install` adds a local CA to the system, Chrome and Firefox
trust stores, so browsers show a padlock. Keep `$(mkcert -CAROOT)/rootCA-key.pem`
private. Undo: `mkcert -uninstall`.

**SDK zip.** Download the AEM SDK from https://experience.adobe.com/#/downloads
and place it in `SDK_DIR` (for example `sdk/aem-sdk-2026.9.28386….zip`). The
dispatcher tools are inside it, so there's nothing else to download.

---

## Step 2 — Configuration (`.env`)

```bash
make env          # creates .env from .env.example if missing
```

Review at least: `CUSTOM_DOMAINS`, `SDK_DIR`, `INSTALL_DIR`, `JAVA_HOME`, and
the ports (`DISPATCHER_PORT=9999`, `NGINX_HTTPS_PORT=443`). `.env` is gitignored.

---

## Step 3 — Verify prerequisites

```bash
make prereq
make paths
```

This checks the installer for your OS, curl/unzip/openssl, Docker (daemon and
compose v2), Java ≥ `JAVA_REQUIRED`, mkcert (optional), `.env`, the SDK zip, and
that every install path is writable.
**Expected:** `All prerequisites satisfied.`
**Changes:** nothing.

---

## Step 4 — Unpack the SDK and create Author + Publish

```bash
make sdk-unpack   # 01: SDK_DIR/aem-sdk*.zip → SDK_DIR/aem-sdk-<ver>/
make instances    # 02: jar → INSTALL_DIR/author, /publish + unpack crx-quickstart
# or both:  make sdk
```

**Check:**
```bash
ls -lh sdk/aem-sdk-*/          # quickstart jar + aem-sdk-dispatcher-tools-*-unix.sh
ls sdk/author sdk/publish      # aem-*-p450x.jar + crx-quickstart/
```
Safe to re-run: existing jars and repositories are never overwritten.
**Undo:** `rm -rf sdk/aem-sdk-*/`. The zip stays. Remove the instances with `make uninstall`.

---

## Step 5 — SSL certificate

```bash
make certs
openssl x509 -in sdk/certs/server.crt -noout -subject -issuer -dates
```

This creates `INSTALL_DIR/certs/server.crt` + `.key`, with SANs for every
`CUSTOM_DOMAINS` entry plus `localhost` and `127.0.0.1`. It uses mkcert when
installed (issuer: *mkcert development CA*); otherwise openssl self-signed
(browser warning). It regenerates only when the domain list changes, or with
`FORCE=1 make certs`.
**Changes:** only files under `INSTALL_DIR/certs`.
**Undo:** `rm -f sdk/certs/server.* sdk/certs/.server.sans`

---

## Step 6 — Dispatcher tools and image

```bash
make dispatcher
make dispatcher-validate
```

`make dispatcher`:
1. Self-extracts `aem-sdk-dispatcher-tools-*-unix.sh` into `SDK_DIR/dispatcher-sdk-X.Y.Z/`
   (run with `--nox11 --quiet`, so it never opens a separate terminal window).
2. Seeds `INSTALL_DIR/dispatcher/src` with Adobe's default config, only if empty.
3. Loads the image for your CPU (`lib/dispatcher-publish-<arch>.tar.gz`, e.g.
   `adobe/aem-cs/dispatcher-publish:2.0.275`) into Docker.
4. Writes `INSTALL_DIR/dispatcher/docker/image.env`.

`make dispatcher-validate` runs Adobe's validator:
- Phase 1: config rules. One warning about `ignoreUrlParameters` on the default farm is expected.
- Phase 2: `httpd -t` in the container.
- Phase 3: immutability check.

**Check:** `docker images adobe/aem-cs/dispatcher-publish`, `ls sdk/dispatcher/src`
**Changes:** one Docker image.
**Undo:** `docker rmi adobe/aem-cs/dispatcher-publish:<ver> && rm -rf sdk/dispatcher-sdk-*/ sdk/dispatcher`

> Adobe's validator mounts `${PWD}/cache`. The Makefile runs it from
> `INSTALL_DIR/dispatcher`, so the cache lands there, not in the project root.

---

## Step 7 — nginx configuration

```bash
make nginx
cat sdk/nginx/conf.d/dev-local-www-brand.com.conf
```

Writes `00-http-redirect.conf` (80 → https) and one `<domain>.conf` per
domain. Each file notes the host path next to each container path:

| Line | Meaning |
|---|---|
| `listen 443 ssl;` | port 443 **inside** the container (host 443 is mapped to it) |
| `ssl_certificate /etc/nginx/certs/server.crt;` | container path = host `INSTALL_DIR/certs/server.crt` |
| `proxy_pass http://aem-dispatcher:80;` | dispatcher container by name (host view: `localhost:9999`) |
| `proxy_set_header Host $host;` | passes the domain on, so the dispatcher can select a vhost |
| `X-Forwarded-Proto https` | AEM builds https links |

Verify the mounts without starting anything: `docker compose config | grep -B1 -A1 '/etc/nginx'`
**Changes:** only text files.
**Undo:** `rm -f sdk/nginx/conf.d/*.conf`

---

## Step 8 — Hosts file

```bash
sudo cp /etc/hosts /etc/hosts.before-stackisle     # your own backup
make hosts                                         # asks for sudo
grep stackisle /etc/hosts
getent hosts dev-local-www-brand.com               # → 127.0.0.1
```

Appends `127.0.0.1  <domain>  # stackisle` for each domain (skipping existing
ones) and flushes the DNS cache. This is the first change to a system file.
Windows: `C:\Windows\System32\drivers\etc\hosts` (Git Bash as Administrator).

**Undo:** `make hosts-remove` removes only the tagged lines and keeps `/etc/hosts.stackisle.bak`.

---

## Step 9 — Start AEM Author and Publish

```bash
make start-aem
bash scripts/06-start-aem.sh status
```

For each instance: `nohup java … -jar aem-<inst>-p<port>.jar -r <inst>,local -p <port> -nofork -nobrowser`.
- PID goes to `INSTALL_DIR/<inst>/aem.pid`; console output to `crx-quickstart/logs/stdout.log`.
- It waits 5s and **fails with the log tail** if Java exits immediately (wrong Java version, port clash).
- Java debug ports 45045/45046 listen on **127.0.0.1 only**.
- 4502/4503 listen on all interfaces, because the dispatcher container needs to reach Publish.

**First boot takes 5–10 minutes.**
```bash
tail -f sdk/author/crx-quickstart/logs/error.log
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4502/libs/granite/core/content/login.html   # wait for 200
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4503/libs/granite/core/content/login.html
```

`status` confirms each PID really is `java … -jar aem-<inst>-p<port>.jar`. It
drops stale PIDs and adopts instances started by hand:
```
  ✔ Author running (PID 3098146), listening on :4502
  ✔ Publish running (PID 4007060), listening on :4503
```

Start a single instance: `bash scripts/06-start-aem.sh start publish`

---

## Step 9b — (optional) WKND sample site

```bash
make wknd                    # AEM already running
# or in one go with step 9:
make start-aem WKND=1
```

Installs Adobe's WKND reference site (`aem-guides-wknd.all-<ver>.zip`) on Author and Publish:
1. Resolves the **latest** release on github.com/adobe/aem-guides-wknd (or `WKND_VERSION` in `.env`)
   and downloads it once to `SDK_DIR/packages/`. If GitHub isn't reachable, it uses a zip already there.
2. Waits until AEM is ready (login page + all OSGi bundles active), with **no timeout**.
   Progress every 30s; Ctrl+C stops only the waiting.
3. Skips an instance where this version is already installed (`FORCE=1 make wknd` reinstalls).
4. Uploads and installs it through the Package Manager API (`/crx/packmgr/service.jsp`, admin login
   from `AEM_ADMIN_USER`/`AEM_ADMIN_PASSWORD`), waits for bundles again, and checks
   `/content/wknd/us/en.html`.

**Check:** `make urls` lists your Author URL (open `/sites.html` there). After steps 10–11,
run `make smoke` to test `SMOKE_PATH` through every hop.
**Changes:** content in the AEM repositories, plus the zip in `SDK_DIR/packages/`.
**Undo:** uninstall/delete the package in Package Manager (`/crx/packmgr` on each instance);
`make uninstall` removes the repositories entirely.

---

## Step 10 — Start the dispatcher container

```bash
make start-dispatcher
docker ps --filter name=aem-dispatcher
make smoke          # "Dispatcher → Publish" and "Dispatcher as <domain>" should be 200
```

`make smoke` prints the exact commands it runs, built from `.env`. With the defaults they are:
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9999/content/wknd/us/en.html
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: dev-local-www-brand.com" http://localhost:9999/content/wknd/us/en.html
```
(`DISPATCHER_URL` + `SMOKE_PATH`; the Host header uses the first `CUSTOM_DOMAINS` entry, as nginx sends it.)

Creates network `aem-local-net`, volume `aem-dispatcher-cache` and container
`aem-dispatcher` (host port `DISPATCHER_PORT`). The service mirrors Adobe's
`bin/docker_run.sh`: same env and mounts, including `import_sdk_config.sh`, the
hook that applies your `dispatcher/src`.

| Code | Meaning |
|---|---|
| 200 | dispatcher → Publish works |
| 404 | dispatcher works; path filtered or missing |
| 502 / 503 | dispatcher up, can't reach Publish — `docker logs aem-dispatcher` |
| 000 | container not answering — `docker ps`, `docker logs` |

**Domains.** Adobe's defaults accept every hostname: `ServerAlias "*"` in
`default.vhost`, and `"*"` in `default_virtualhosts.any`. Both files are
immutable on AEMaaCS (*DO NOT EDIT*). For per-domain config, edit
`conf.dispatcher.d/virtualhosts/virtualhosts.any` and add your own vhost in
`conf.d/available_vhosts/` + `enabled_vhosts/`.

**Undo:** `make stop-dispatcher`

---

## Step 11 — Start the nginx SSL proxy

```bash
ss -ltnp | grep -E ':(80|443) '        # must be empty first
make start-nginx
make smoke          # every "Site <domain>" line should be 200 (no -k: proves the cert is trusted)
```

The script tests the config first (`nginx -t` in a throwaway container). It
then starts `aem-nginx` on host ports 80 and 443. The first run downloads
`nginx:1.27-alpine` (about 20 MB).
**Undo:** `make stop-nginx`

---

## Step 12 — Health check

```bash
make health       # one-shot
make wait         # poll until healthy (HEALTH_TIMEOUT)
make urls         # every URL of your setup, from .env
make smoke        # SMOKE_PATH through every hop, with the exact curl commands
```

Checks Author, Publish, both containers, dispatcher, every https domain, hosts
entries and cert coverage. A `302` on a site root is normal: `/` redirects to
the start page.

---

## Day to day

| Command | Does |
|---|---|
| `make start` / `make stop` | everything (stop order: nginx → dispatcher → AEM) |
| `make start-aem` / `make stop-aem` | Author + Publish |
| `bash scripts/06-start-aem.sh start\|stop\|status author\|publish` | one instance |
| `make restart` / `make restart-aem` | stop, then start (won't start if stop didn't finish) |
| `make logs-author` / `logs-publish` / `logs-dispatcher` / `logs-nginx` | follow logs |
| `make reload-nginx` | test and hot-reload nginx after `make nginx` |
| `make help` | all targets |

### Stopping AEM is always graceful

`stop` sends **SIGTERM**, the same as Adobe's `crx-quickstart/bin/stop`. AEM
stops its bundles, closes the Oak repository and flushes indexes. The script
**waits until the JVM has exited**, with no fixed timeout, and prints progress
every 30s. It **never** uses `kill -9`, which can corrupt the repository or
indexes. Ctrl+C only stops the waiting; AEM keeps shutting down.
`AEM_STOP_TIMEOUT` (seconds) limits the waiting for unattended use; 0, the
default, means no limit.

### Adding a domain

```bash
# .env — append to CUSTOM_DOMAINS
make certs nginx hosts reload-nginx
```

---

## Undo / uninstall

| Step | Undo |
|---|---|
| 4 SDK / instances | `rm -rf sdk/aem-sdk-*/` · instances via `make uninstall` |
| 5 cert | `rm -f sdk/certs/server.* sdk/certs/.server.sans` |
| 6 dispatcher | `docker rmi adobe/aem-cs/dispatcher-publish:<ver>`, `rm -rf sdk/dispatcher-sdk-*/ sdk/dispatcher` |
| 7 nginx conf | `rm -f sdk/nginx/conf.d/*.conf` |
| 8 hosts | `make hosts-remove` (or restore `/etc/hosts.before-stackisle`) |
| 9–11 services | `make stop` |

**Everything at once:** `make uninstall`. It asks you to type `yes`, then:
1. stops AEM gracefully, and **aborts** if AEM is still shutting down;
2. removes the validator cache, containers, network, cache volume and images;
3. removes the hosts entries;
4. removes the instances, unpacked SDK, cert, nginx conf and image reference;
5. removes `dispatcher/src` only if it's unmodified.

It keeps the SDK zip, `.env` and the scripts. System packages (Java, Docker
group, mkcert) are not removed; it prints the commands for that.

---

## Pitfalls we hit (and how the scripts handle them)

| Symptom | Cause | Now |
|---|---|---|
| `Quickstart requires a Java Specification 21 VM` | SDK 2026.x needs Java 21 | `JAVA_REQUIRED=21`; start fails fast with the log tail |
| `docker ps` → permission denied right after `usermod` | group applies to new logins only | log out/in, or `newgrp docker` |
| `cache/` appeared in the project root, root-owned | Adobe validator mounts `${PWD}/cache` | validator runs from `INSTALL_DIR/dispatcher`; delete an old one with `sudo rm -rf cache` |
| `status`: "Port answers, but not from this Author" | `aem.pid` held a wrapper shell's PID | only Java is backgrounded; running instances are adopted |
| Old error still in `stdout.log` | instance was skipped, so the log wasn't rewritten | compare log timestamps; check with `status` |
| A log file can't be deleted | file owned by root (e.g. AEM once run with `sudo`) | `ls -l` to check the owner; never start AEM with sudo |
| Dispatcher ignores `src` | Adobe's config hook not mounted | compose mirrors `docker_run.sh` |
| Dispatcher tools open a separate terminal window | makeself spawns an xterm without a TTY | extractor runs with `--nox11 --quiet` |
| `ssl_certificate /etc/nginx/...` looks wrong | container path, not a host path | explained in each generated file |
