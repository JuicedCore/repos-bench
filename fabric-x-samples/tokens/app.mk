#
# Copyright IBM Corp. All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#

export PLATFORM
ifeq ($(PLATFORM),fabric3)
	COMPOSE_ARGS := -f compose.yml -f compose-endorser2.yml
else ifeq ($(PLATFORM),drunix)
	COMPOSE_ARGS := -f compose.yml -f compose-endorser2.yml
endif
CONTAINER_CLI ?= docker

# Setup application
.PHONY: setup-app
setup-app: build-app
	./scripts/gen_crypto.sh

# Setup application
.PHONY: build-app
build-app:
	$(CONTAINER_CLI) compose $(COMPOSE_ARGS) build

# Start application
.PHONY: start-app
start-app:
	$(CONTAINER_CLI) compose $(COMPOSE_ARGS) up -d
	@$(MAKE) --no-print-directory wait-app

# Restart application
.PHONY: restart-app
restart-app: build-app
	$(CONTAINER_CLI) compose $(COMPOSE_ARGS) down
	$(CONTAINER_CLI) compose $(COMPOSE_ARGS) up -d
	@$(MAKE) --no-print-directory wait-app

# Wait until the application can serve requests: every node answers /readyz and, except on
# Fabric-X (where the parameters only exist after /endorser/init), the token service can load
# its public parameters. On classic Fabric these come from the namespace chaincode, which
# lags a few seconds behind the containers on a fresh network.
APP_READY_PORTS := 9100 9300 9500 9600
ifeq ($(filter $(PLATFORM),fabricx xdev),)
APP_READY_PORTS += 9400
endif
.PHONY: wait-app
wait-app:
	@for port in $(APP_READY_PORTS); do \
		n=0; until curl -sf "http://localhost:$$port/readyz" >/dev/null; do \
			n=$$((n+1)); [ $$n -ge 60 ] && { echo "app on port $$port not ready after 120s"; exit 1; }; sleep 2; \
		done; \
	done
	@if [ -z "$(filter $(PLATFORM),fabricx xdev)" ]; then \
		n=0; until curl -sf http://localhost:9500/owner/accounts/alice >/dev/null; do \
			n=$$((n+1)); [ $$n -ge 60 ] && { echo "token service not ready after 120s"; exit 1; }; sleep 2; \
		done; \
	fi
	@echo "application ready"

# Stop application
.PHONY: stop-app
stop-app:
	PLATFORM=$(PLATFORM) $(CONTAINER_CLI) compose $(COMPOSE_ARGS) stop

# Teardown application
.PHONY: teardown-app
teardown-app:
	$(CONTAINER_CLI) compose $(COMPOSE_ARGS) down
	rm -rf "$(CONF_ROOT)"/*/data

# Clean just the databases.
.PHONY: clean-data
clean-data:
	rm -rf "$(CONF_ROOT)"/*/data

# Clean everything and remove all the keys
.PHONY: clean-app
clean-app:
	rm -rf "$(CONF_ROOT)"/*/keys "$(CONF_ROOT)"/*/data "$(CONF_ROOT)"/namespace/*.json
