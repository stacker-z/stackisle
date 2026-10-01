# ─────────────────────────────────────────────────────────────
# stackisle — AEMaaCS local dev
#
#   Browser → https://<domain>  [nginx container   certs/ + nginx/conf.d/]
#     → aem-dispatcher:80 / localhost:$(DISPATCHER_PORT)  [dispatcher container  dispatcher/src/]
#       → host.docker.internal:4503  [AEM Publish — local Java]
#
#   make            full setup + start + wait until healthy (scripts 00 → 09)
#   make help       list all targets
#
# Config lives in .env (see .env.example). Scripts load it themselves via
# scripts/lib/common.sh, so quoted values like CUSTOM_DOMAINS="a b" work.
#
# Extending: drop a <stack>.mk file into mk/ — it is included automatically
# and its "## " commented targets show up in `make help`.
# ─────────────────────────────────────────────────────────────

SHELL        := bash
.SHELLFLAGS  := -e -o pipefail -c
.DEFAULT_GOAL := all
.NOTPARALLEL:
MAKEFLAGS    += --no-print-directory

S := scripts

BOLD  := \033[1m
RESET := \033[0m
GREEN := \033[32m
CYAN  := \033[36m

.PHONY: all help env install-prereq prereq setup \
        sdk sdk-unpack instances certs dispatcher dispatcher-validate nginx hosts hosts-remove \
        start start-aem start-dispatcher start-nginx wknd \
        stop stop-aem stop-dispatcher stop-nginx restart restart-aem reload-nginx \
        set-paths paths status health urls smoke wait logs logs-author logs-publish logs-dispatcher logs-nginx \
        clean uninstall

##@ Main
all: env prereq setup start wait ## Full setup, start everything, wait until healthy (default)
	@echo -e "$(GREEN)$(BOLD)stackisle is up.$(RESET)"

help: ## Show this help
	@echo ""
	@echo -e "  $(BOLD)stackisle — AEM local dev$(RESET)   usage: make [target]"
	@# POSIX regex only (no `.*?`) so BSD awk on macOS behaves like GNU awk
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ { printf "\n  $(BOLD)%s$(RESET)\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_.-]+:.*## / { printf "    $(CYAN)%-20s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""

##@ Prerequisites
env: ## Create .env from .env.example if missing
	@if [ ! -f .env ]; then \
	  cp .env.example .env; \
	  echo -e "  $(GREEN)✔$(RESET) Created .env from .env.example — review domains/ports in .env"; \
	fi

install-prereq: ## Run the platform prereq installer (mac/linux; Windows → PowerShell)
	@case "$$OSTYPE" in \
	  darwin*) bash prereq/mac/install-prereq.sh ;; \
	  linux*)  bash prereq/linux/install-prereq.sh ;; \
	  *) echo "Windows: run in Admin PowerShell → powershell -File prereq/windows/install-prereq.ps1"; exit 1 ;; \
	esac

prereq: ## 00 Verify Java 17+, Docker, compose, tools, SDK zip
	@bash $(S)/00-check-prereq.sh

##@ Setup
setup: sdk certs dispatcher nginx hosts ## 01-05 + hosts (no start)

sdk: sdk-unpack instances ## 01+02 Unpack SDK, create author/ + publish/

sdk-unpack: ## 01 Unpack sdk/aem-sdk*.zip
	@bash $(S)/01-unpack-sdk.sh

instances: ## 02 Create author/ and publish/ instances
	@bash $(S)/02-create-author-publish.sh

certs: ## 03 Generate certs/server.crt+key for all domains (FORCE=1 to regenerate)
	@bash $(S)/03-create-cert.sh

dispatcher: ## 04 Extract dispatcher tools, seed dispatcher/src, load image
	@bash $(S)/04-install-dispatcher.sh

dispatcher-validate: ## Validate DISPATCHER_SRC_DIR with the SDK validator
	@source $(S)/lib/common.sh; d="$$(dispatcher_sdk_dir)"; \
	  [ -n "$$d" ] || fail "Dispatcher SDK not extracted. Run: make dispatcher"; \
	  mkdir -p "$$DISPATCHER_CACHE_DIR"; \
	  cd "$$DISPATCHER_DIR" && unset CACHE_FOLDER && \
	  bash "$$d/bin/validate.sh" "$$DISPATCHER_SRC_DIR"
	@# ^ Adobe's docker_run.sh mounts $${PWD}/cache — running from DISPATCHER_DIR keeps it
	@#   at INSTALL_DIR/dispatcher/cache instead of the project root.

nginx: ## 05 Generate nginx/conf.d for all CUSTOM_DOMAINS
	@bash $(S)/05-create-nginx-config.sh

hosts: ## Map CUSTOM_DOMAINS → 127.0.0.1 in hosts file (sudo)
	@bash update-etc-hosts.sh add

hosts-remove: ## Remove stackisle entries from hosts file (sudo)
	@bash update-etc-hosts.sh remove

##@ Run
start: start-aem start-dispatcher start-nginx ## 06-08 Start AEM, dispatcher, nginx

start-aem: ## 06 Start Author + Publish (add WKND=1 to also install the WKND sample site)
	@bash $(S)/06-start-aem.sh start
	@if [ "$(WKND)" = "1" ]; then bash $(S)/install-wknd.sh; fi

wknd: ## Install WKND sample site on Author + Publish (FORCE=1 to reinstall)
	@bash $(S)/install-wknd.sh

start-dispatcher: ## 07 Start dispatcher container
	@bash $(S)/07-start-dispatcher.sh start

start-nginx: ## 08 Start nginx SSL container
	@bash $(S)/08-start-nginx.sh start

stop: stop-nginx stop-dispatcher stop-aem ## Stop everything
	@echo -e "  $(GREEN)✔ All services stopped.$(RESET)"

stop-nginx: ## Stop nginx container
	@bash $(S)/08-start-nginx.sh stop

stop-dispatcher: ## Stop dispatcher container
	@bash $(S)/07-start-dispatcher.sh stop

stop-aem: ## Stop Author + Publish
	@bash $(S)/06-start-aem.sh stop

restart: stop start ## Restart everything

restart-aem: stop-aem start-aem ## Restart Author + Publish only

reload-nginx: ## Test + hot-reload nginx config (after make nginx)
	@bash $(S)/08-start-nginx.sh reload

set-paths: ## Set paths in .env: make set-paths SDK_DIR=<path> INSTALL_DIR=<path> (either or both)
	@bash $(S)/set-paths.sh \
	  "$(if $(filter command line,$(origin SDK_DIR)),$(SDK_DIR))" \
	  "$(if $(filter command line,$(origin INSTALL_DIR)),$(INSTALL_DIR))"

paths: ## Show the layout derived from SDK_DIR + INSTALL_DIR (.env) — read-only
	@source $(S)/lib/common.sh; echo ""; \
	  for v in $$INSTALL_PATH_VARS; do printf "  $(CYAN)%-19s$(RESET) %s\n" "$$v" "$${!v}"; done; echo ""

##@ Observe
health: ## 09 One-shot health check of every hop
	@bash $(S)/09-health-check.sh

urls: ## Print every URL of this setup (built from .env)
	@bash $(S)/urls.sh urls

smoke: ## Test SMOKE_PATH on every hop, printing the exact curl used
	@bash $(S)/urls.sh smoke

status: health ## Alias for health

wait: ## 09 Poll until healthy (HEALTH_TIMEOUT, default 900s)
	@bash $(S)/09-health-check.sh --wait

logs: logs-author ## Alias for logs-author

logs-author: ## Tail Author error.log
	@source $(S)/lib/common.sh; tail -F "$$AUTHOR_DIR/crx-quickstart/logs/error.log"

logs-publish: ## Tail Publish error.log
	@source $(S)/lib/common.sh; tail -F "$$PUBLISH_DIR/crx-quickstart/logs/error.log"

logs-dispatcher: ## Follow dispatcher logs (also saved to DISPATCHER_DIR/logs/)
	@source $(S)/lib/common.sh; mkdir -p "$$DISPATCHER_LOG_DIR"; \
	  compose logs -f --tail=200 dispatcher | tee -a "$$DISPATCHER_LOG_DIR/dispatcher.log"

logs-nginx: ## Follow nginx logs
	@source $(S)/lib/common.sh; compose logs -f --tail=200 nginx

##@ Cleanup
clean: ## Stop containers, remove generated certs/nginx conf/image ref (keeps AEM + SDK)
	@source $(S)/lib/common.sh; compose down --remove-orphans 2>/dev/null || true; \
	  rm -f "$$CERT_FILE" "$$KEY_FILE" "$$CERTS_DIR/.$$CERT_NAME.sans" "$$DISPATCHER_IMAGE_FILE"; \
	  grep -l "Auto-generated by 05-create-nginx-config.sh" "$$NGINX_CONF_DIR"/*.conf 2>/dev/null | xargs rm -f || true
	@echo -e "  $(GREEN)✔$(RESET) Cleaned generated files. AEM instances, SDK and dispatcher/src kept."

uninstall: ## Revert everything make created: containers, images, hosts entries, AEM repos (asks)
	@bash $(S)/uninstall.sh

# ── Extension point: additional stacks (magento.mk, k8s.mk, ...) ──
-include mk/*.mk
