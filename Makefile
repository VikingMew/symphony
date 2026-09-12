.PHONY: help all setup deps build worker-image worker-image-check

MIX ?= mix
WORKER_IMAGE ?= symphony-worker:local
WORKER_SOURCE_REVISION ?= $(shell git rev-parse HEAD)

help:
	@echo "Targets: all, setup, deps, build, worker-image, worker-image-check"
	@echo "Quality checks: scripts/check.sh, scripts/unit.sh, scripts/dialyzer.sh"
	@echo "Manual live E2E: scripts/e2e.sh with credentials"

all: build

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

worker-image:
	docker build --target execution-worker \
		--build-arg SYMPHONY_WORKER_IMAGE=$(WORKER_IMAGE) \
		--build-arg SYMPHONY_WORKER_SOURCE_REVISION=$(WORKER_SOURCE_REVISION) \
		--tag $(WORKER_IMAGE) .

worker-image-check: worker-image
	test "$$(docker run --rm --entrypoint id $(WORKER_IMAGE) -u)" != "0"
	docker run --rm --entrypoint bash $(WORKER_IMAGE) -lc \
		'command -v codex && command -v git && command -v make && command -v cc && command -v mix && command -v elixir'
	git archive HEAD | docker run --rm --interactive --entrypoint bash $(WORKER_IMAGE) -lc \
		'mkdir /worker/workspaces/symphony && tar -x -C /worker/workspaces/symphony && cd /worker/workspaces/symphony && scripts/check.sh'
