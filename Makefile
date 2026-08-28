.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e pg-smoke worker-image worker-image-check

MIX ?= mix
WORKER_IMAGE ?= symphony-worker:local
WORKER_SOURCE_REVISION ?= $(shell git rev-parse HEAD)

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, pg-smoke, worker-image-check, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

pg-smoke:
	$(MIX) symphony.postgres_smoke

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
		'mkdir /worker/workspaces/symphony && tar -x -C /worker/workspaces/symphony && cd /worker/workspaces/symphony && make all'

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
