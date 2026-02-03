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

.PHONY: up down logs ps build pull preflight install help

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

install:
	./install.sh

help:
	@echo "MistServer Bootstrap"
	@echo ""
	@echo "Docker (full stack):"
	@echo "  make up [CADDY=true] [GPU=true] [DETACH=true] [SERVICES=\"mist grafana\"]"
	@echo "  make down"
	@echo "  make logs [SERVICES=...]"
	@echo "  make ps"
	@echo "  make build"
	@echo ""
	@echo "Native installation:"
	@echo "  make install         Install CLI tools to /usr/local/bin"
	@echo ""
	@echo "CLI tools (after 'make install'):"
	@echo "  mist-install         Install MistServer (source build or binary)"
	@echo "  mist-passwd          Change admin password (requires restart)"
	@echo "  mist-https           Enable/disable HTTPS via Caddy"
	@echo "  mist-monitoring      Enable/disable Prometheus + Grafana"
	@echo "  mist-status          Show MistServer status"
	@echo "  mist-videogen        Generate test video stream"
	@echo ""
	@echo "Flags:"
	@echo "  CADDY=true           Include Caddy reverse proxy"
	@echo "  GPU=true             Include GPU passthrough (Linux only)"
	@echo "  PREFLIGHT=false      Skip preflight checks"
	@echo "  DETACH=true          Run in background (-d)"
