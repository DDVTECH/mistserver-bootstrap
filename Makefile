COMPOSE ?= docker compose
COMPOSE_FILES := -f docker-compose.yml
CADDY ?= false
GPU ?= false
PREFLIGHT ?= true
DETACH ?= false
SERVICES ?=

ifeq ($(GPU),true)
COMPOSE_FILES += -f docker-compose.gpu.yml
endif

ifeq ($(CADDY),true)
PROFILES := --profile caddy
else
PROFILES :=
endif

COMPOSE_ARGS := $(COMPOSE_FILES) $(PROFILES)

ifneq ($(strip $(SERVICES)),)
SERVICE_ARGS := $(strip $(SERVICES))
else
SERVICE_ARGS :=
endif

ifeq ($(DETACH),true)
UP_FLAG := -d
else
UP_FLAG :=
endif

.PHONY: up down logs ps build pull preflight help

up:
ifneq ($(PREFLIGHT),false)
	ENABLE_CADDY=$(CADDY) ./scripts/preflight.sh
endif
	$(COMPOSE) $(COMPOSE_ARGS) up --build $(UP_FLAG) $(SERVICE_ARGS)

down:
	$(COMPOSE) $(COMPOSE_ARGS) down

logs:
	$(COMPOSE) $(COMPOSE_ARGS) logs -f $(SERVICE_ARGS)

ps:
	$(COMPOSE) $(COMPOSE_ARGS) ps

build:
ifneq ($(PREFLIGHT),false)
	ENABLE_CADDY=$(CADDY) ./scripts/preflight.sh
endif
	$(COMPOSE) $(COMPOSE_ARGS) build $(SERVICE_ARGS)

pull:
	$(COMPOSE) $(COMPOSE_ARGS) pull $(SERVICE_ARGS)

preflight:
	ENABLE_CADDY=$(CADDY) ./scripts/preflight.sh

help:
	@echo "MistServer bootstrap helpers"
	@echo "  make up [CADDY=true] [GPU=true] [DETACH=true] [SERVICES=\"mist grafana\"]"
	@echo "  make down"
	@echo "  make logs [SERVICES=...]"
	@echo "  make ps"
	@echo "  make build"
	@echo "Flags:"
	@echo "  CADDY=true        include reverse proxy profile"
	@echo "  GPU=true          include docker-compose.gpu.yml overrides"
	@echo "  PREFLIGHT=false   skip ./scripts/preflight.sh"
	@echo "  DETACH=true       equivalent to docker compose up -d"
