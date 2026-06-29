# EVM Oracle Demo — Makefile.
#
# Thin wrappers around docker compose. The deploy script (scripts/deploy.sh)
# is the production interface; this Makefile is for local development.

.PHONY: help submodules submodules-update submodules-status config build up down logs ps restart shellcheck validate clean

COMPOSE = docker compose -f docker/docker-compose.yml
COMPOSE_PROD = $(COMPOSE) -f docker/docker-compose.prod.yml

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  \033[1m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

submodules: ## Initialise + fetch every submodule at its pinned SHA.
	git submodule update --init --recursive

submodules-update: ## Bump each submodule to the tip of its tracked branch (pinning happens via commit on this repo).
	git submodule update --init --recursive --remote
	@echo "Submodule pointers updated. Review with 'git status', commit to pin."

submodules-status: ## Show the SHA each submodule is pinned at.
	git submodule status

config: ## Validate the merged dev compose file.
	$(COMPOSE) config -q && echo "dev config OK"

config-prod: ## Validate the merged prod compose file.
	$(COMPOSE_PROD) config -q && echo "prod config OK"

build: ## Build every service image locally (uses dev compose).
	$(COMPOSE) build

up: ## Bring the dev stack up in the background.
	$(COMPOSE) up -d

up-build: ## Build then bring the dev stack up.
	$(COMPOSE) up -d --build

down: ## Stop the dev stack and remove containers (volumes preserved).
	$(COMPOSE) down

down-volumes: ## Stop the dev stack and wipe volumes (destroys DB data).
	$(COMPOSE) down -v

logs: ## Tail logs from every service.
	$(COMPOSE) logs -f --tail=100

ps: ## Show running containers.
	$(COMPOSE) ps

restart: ## Restart every service without rebuild.
	$(COMPOSE) restart

shellcheck: ## Lint every bash script in scripts/ and docker/postgres-init/.
	shellcheck scripts/*.sh docker/postgres-init/*.sh

validate: config config-prod shellcheck ## Run every static validation.
	@echo "All static checks passed."

clean: down-volumes ## Stop everything + wipe volumes.
	@echo "Stack cleaned."
