# Troubleshooting Reference

> Loaded by the stackisle skill when the user reports an error or something
> isn't working. Work through the relevant section top to bottom.
> **The user runs every command** — give the command and what to look for,
> then wait for the pasted output (see CLAUDE.md, Working agreement).
>
> Paths below assume the defaults `SDK_DIR="./sdk"` and `INSTALL_DIR="./sdk"`.
> `make paths` shows the real locations.

---

## Java errors

### `command not found: java`
```bash
make install-prereq   # mac/linux; Windows: prereq/windows/install-prereq.ps1
```

### `Java X found — Java 21+ is required`  /  `Quickstart requires a Java Specification 21 VM`
AEM SDK 2026.x needs Java 21 and exits immediately on 17. `make start-aem` shows
the last log lines and fails.
```bash
sudo apt install -y openjdk-21-jdk           # linux (Ubuntu/Debian)
brew install --cask temurin@21               # mac
ls /usr/lib/jvm/                             # linux: what's installed
/usr/libexec/java_home -V                    # mac:   what's installed
# .env:  JAVA_HOME="/usr/lib/jvm/java-21-openjdk-amd64"   (linux; -arm64 on ARM)
# .env:  JAVA_HOME="$(/usr/libexec/java_home -v 21)"      (mac — paste the resolved path)
make prereq
```
If a newer SDK demands more, raise `JAVA_REQUIRED` in `.env`.

---

## SDK zip errors

### `No SDK found` / `No aem-sdk*.zip in sdk`
```bash
ls -la sdk/            # zip must start with aem-sdk, e.g. sdk/aem-sdk-2026.9.28386....zip
```
Download: https://experience.adobe.com/#/downloads → "AEM SDK".

### `aem-sdk-quickstart-*.jar not found`
```bash
ls sdk/aem-sdk-*/
# Empty/odd → corrupt or wrong zip: rm -rf sdk/aem-sdk-*/ then make sdk
```

### `aem-sdk-dispatcher-tools-*-unix.sh not found`
Very old SDKs ship the tools separately. Put the `-unix.sh` into `sdk/aem-sdk-*/`, then `make dispatcher`.

---

## Docker errors

### `Docker daemon is not running` / `permission denied ... docker.sock`
- mac/windows: start Docker Desktop.
- linux: `sudo systemctl start docker`; for permission, `sudo usermod -aG docker $USER`,
  then **log out and back in** (`newgrp docker` works for one terminal only). The group
  change doesn't apply to sessions that were already open, Claude Code included.

### `make health`: "Docker CLI cannot reach the daemon from this shell", but the sites work
The containers are fine. This **shell** can't talk to Docker. Most often it's
`permission denied`: the terminal, or the IDE that opened it (IntelliJ, VS Code),
was started before the user joined the `docker` group. Open a new login shell
(log out/in, or restart the IDE), or run `newgrp docker`. Otherwise check
`docker context show` and `echo $DOCKER_HOST`.

---

## Dispatcher errors

### `Could not determine dispatcher image`
```bash
ls sdk/dispatcher-sdk-*/lib                                   # image tarballs (amd64/arm64)
grep -oE 'adobe/[a-z-]+/dispatcher-publish[^ "]*' sdk/dispatcher-sdk-*/bin/docker_run.sh
# then in .env: DISPATCHER_IMAGE="adobe/aem-cs/dispatcher-publish:<ver>" and: make dispatcher
```

### Dispatcher ignores my `dispatcher/src` changes
The config is applied at container start by Adobe's `import_sdk_config.sh` hook.
`docker-compose.yml` mounts it, mirroring `bin/docker_run.sh`. After editing
`sdk/dispatcher/src`: `make dispatcher-validate`, then `make stop-dispatcher start-dispatcher`.

### `aem-dispatcher` container exiting / restarting
```bash
docker logs aem-dispatcher
make dispatcher-validate             # phase 1 rules, 2 httpd -t, 3 immutability
```
Phase 3 fails → an immutable Adobe file (e.g. `default.vhost`, `default_virtualhosts.any`)
was edited. Make changes in your own copies instead (`virtualhosts.any`, your own vhost).

### `cache/` folder appears in the project root (owned by root)
Adobe's `docker_run.sh` mounts `${PWD}/cache`. That happens if `validate.sh` is
run by hand from the project root. `make dispatcher-validate` runs it from
`sdk/dispatcher` instead. To remove the stray folder:
```bash
sudo rm -rf /full/path/to/stackisle/cache
```

### Dispatcher returns 502/503
Dispatcher is up but can't reach Publish.
```bash
curl -I http://localhost:4503/libs/granite/core/content/login.html   # publish up?
docker exec aem-dispatcher sh -c 'wget -qO- -S http://host.docker.internal:4503/ 2>&1 | head -3'
sudo ufw allow in on docker0 to any port 4503     # linux: firewall blocking docker0 → host
```

---

## nginx / port errors

### `aem-nginx` not starting / `nginx config test failed`
```bash
ls -la sdk/certs/                    # server.crt + server.key must exist
make certs nginx
make start-nginx                     # re-runs nginx -t and prints the error
```
`host not found in upstream "aem-dispatcher"` → start the dispatcher first: `make start-dispatcher`.

### `ssl_certificate /etc/nginx/certs/...` looks wrong
It's a container path. `docker-compose.yml` mounts `INSTALL_DIR/certs` there,
and each generated file has a `# host: ...` comment next to it. Verify with
`docker compose config | grep -B1 -A1 /etc/nginx`.

### `Port 9999 / 80 / 443 is in use`
```bash
ss -ltnp | grep -E ':(80|443|9999) '          # linux
lsof -nP -iTCP:443 -sTCP:LISTEN               # mac
```
Stop the other service (e.g. a host nginx or Apache), or change
`DISPATCHER_PORT` / `NGINX_HTTP_PORT` / `NGINX_HTTPS_PORT` in `.env`, then run `make nginx restart`.

---

## AEM start / stop / status

### `status`: "Port 4502 answers, but not from this Author (no matching java process)"
`aem.pid` doesn't point at `java … -jar aem-author-p4502.jar`. It's stale, or
the instance was started by hand with a different command line. `status`,
`start` and `stop` now adopt a running instance automatically. If the message
persists:
```bash
pgrep -af 'java .*-jar aem-'        # what is actually running?
```

### Publish/Author "not starting" but the log shows an old error
The instance was skipped, so `stdout.log` wasn't rewritten. Compare the timestamps
(`ls -l sdk/*/crx-quickstart/logs/stdout.log`; mac: `ls -lT`) and check
`bash scripts/06-start-aem.sh status`.

### A log file can't be deleted ("locked")
On Linux/macOS this almost always means it's **owned by root**, because AEM or
Docker once ran as root.
```bash
ls -l sdk/publish/crx-quickstart/logs/
```
Never start AEM with `sudo`. Remove root-owned leftovers with `sudo rm`, only while AEM is stopped.

### `address already in use` on 4502/4503
```bash
bash scripts/06-start-aem.sh status   # is it our instance?
make stop-aem                         # graceful
ss -ltnp | grep ':4502'               # (mac: lsof -nP -iTCP:4502 -sTCP:LISTEN) something else?
```
Don't `kill -9` an AEM process. Stop it gracefully.

### `make stop-aem` takes long
That's expected on large repositories or during reindexing. It sends SIGTERM
and waits until the JVM exits, with no timeout by default and never `kill -9`.
Watch it: `tail -f sdk/author/crx-quickstart/logs/error.log`. Ctrl+C only stops
the waiting; AEM keeps shutting down cleanly.

### AEM boots but login page shows 404 / 503
First boot takes 5–10 min.
```bash
make wait
make logs-author                                   # error.log
tail -f sdk/author/crx-quickstart/logs/stdout.log  # JVM start errors
```

### `Unrecognized VM option 'MaxPermSize'`
Remove `-XX:MaxPermSize` from `AEM_JVM_OPTS` in `.env`.

### Out of memory / crashes after boot
Adjust `AEM_JVM_OPTS` in `.env` (`-Xmx2048m` for 8 GB RAM, `-Xmx4096m` for 16 GB+), then `make restart-aem`.

---

## SSL / HTTPS errors

### Browser shows "Not Secure"
The cert came from openssl (mkcert not installed).
```bash
make install-prereq                  # installs mkcert
FORCE=1 make certs && make reload-nginx
```
Firefox needs `nss` (mac) / `libnss3-tools` (linux) so mkcert can add its CA.

### `NET::ERR_CERT_COMMON_NAME_INVALID` after adding a domain
```bash
make certs nginx hosts reload-nginx  # 03 regenerates when CUSTOM_DOMAINS changes
```

### Domain does not resolve
```bash
grep stackisle /etc/hosts
make hosts
getent hosts dev-local-www-brand.com            # linux
dscacheutil -q host -a name dev-local-www-brand.com   # mac
```

---

## General

```bash
make health                          # every hop in one view
make paths                           # where things are
bash -x scripts/07-start-dispatcher.sh start 2>&1 | tee debug.log
docker ps -a --filter name=aem
make logs-dispatcher / make logs-nginx

make stop clean && make              # start fresh (keeps AEM repos + SDK)
make uninstall && make               # full revert (asks; aborts if AEM still shutting down)
```
