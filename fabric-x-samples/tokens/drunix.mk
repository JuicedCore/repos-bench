#
# Copyright IBM Corp. All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#

# exported vars
#
# DRUNIX_REPO defaults to the drunix checkout living alongside this repo
# (tokens -> fabric-x-samples -> repos-bench -> drunix), so the whole
# repos-bench workspace stays self-contained with no absolute paths baked in.
#
# DRUNIX_NETWORK defaults to the copy nested inside DRUNIX_REPO
# (not the standalone sibling checkout) because network.sh locates the
# locally-built `peer`/`cryptogen`/etc. CLI binaries via a path relative
# to its own location: $(DRUNIX_REPO)/drunix-network/test-network/../../build/bin
# resolves to $(DRUNIX_REPO)/build/bin, which is where `make tools` puts them.
DRUNIX_REPO ?= $(abspath $(CURDIR)/../../drunix)
DRUNIX_NETWORK ?= $(DRUNIX_REPO)/drunix-network
export DRUNIX_REPO
export DRUNIX_NETWORK

CONF_ROOT=conf-drunix
export CONF_ROOT

# Makefile vars
PLAYBOOK_PATH := $(CURDIR)/ansible/playbooks
TARGET_HOSTS ?= all
CONTAINER_CLI ?= docker

DRUNIX_IMAGES := peer orderer vscc

# Install the utilities needed to run the components on the targeted remote hosts (e.g. make install-prerequisites).
.PHONY: install-prerequisites-fabric
install-prerequisites-fabric:
	$(MAKE) -C "$(DRUNIX_REPO)" docker tools
	@for img in $(DRUNIX_IMAGES); do \
		$(CONTAINER_CLI) tag npcioss/drunix-$$img:latest npcioss/drunix-$$img:1.0.0; \
	done

# Build all the artifacts, the binaries and transfer them to the remote hosts (e.g. make setup).
.PHONY: setup-fabric
setup-fabric:

# Build the config artifacts
.PHONY: build-fabric
build-fabric:

# Clean all the artifacts (configs and bins) built on the controller node (e.g. make clean).
.PHONY: clean-fabric
clean-fabric:
	@for d in "$(CONF_ROOT)"/*/ ; do \
		rm -rf "$$d/keys/fabric" "$$d/data"; \
	done

# Start the targeted hosts (e.g. make fabric-fabric start).
.PHONY: start-fabric
start-fabric:
	@[ -f "$(CONF_ROOT)/namespace/zkatdlognoghv1_pp.json" ] || { echo "Error: $(CONF_ROOT)/namespace/zkatdlognoghv1_pp.json not found. Run 'make setup' first."; exit 1; }
	@if $(CONTAINER_CLI) network inspect fabric_test >/dev/null 2>&1; then \
		echo "Error: existing fabric_test network detected. Run 'make teardown' first."; \
		exit 1; \
	fi
	"$(DRUNIX_NETWORK)/test-network/network.sh" up createChannel
	INIT_REQUIRED="--init-required" "$(DRUNIX_NETWORK)/test-network/network.sh" deployCCAAS -ccn token_namespace -ccp "$(abspath $$CONF_ROOT)/namespace" -cci "init"
	FABRIC_SAMPLES="$(DRUNIX_NETWORK)" CONF_ROOT="$(abspath $$CONF_ROOT)" ./scripts/cp_fabric3.sh

# Stopping this network tears it down (new channel and ledger on the next start), so the
# app containers go too: stopped ones would still reference the removed fabric_test network.
.PHONY: stop-fabric
stop-fabric: teardown-app teardown-fabric

# Teardown the targeted hosts (e.g. make fabric-x teardown).
.PHONY: teardown-fabric
teardown-fabric:
	@"$(DRUNIX_NETWORK)/test-network/network.sh" down
	@$(CONTAINER_CLI) rm -f peer0org1_token_namespace_ccaas peer0org2_token_namespace_ccaas
	@for d in "$(CONF_ROOT)"/*/ ; do \
		rm -rf "$$d/keys/fabric" "$$d/data"; \
	done
	@$(CONTAINER_CLI) network inspect fabric_test >/dev/null 2>&1 && $(CONTAINER_CLI) network rm fabric_test || true

# Restart the targeted hosts (e.g. make fabric-x restart).
.PHONY: restart-fabric
restart-fabric: teardown-fabric start-fabric
