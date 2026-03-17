.PHONY: help all setup deps build run fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix
PIPELINE_ROOT ?=
PORT ?= 4000
SYMPHONY_ACK_FLAG ?= --i-understand-that-this-will-be-running-without-the-usual-guardrails
RUN_ARGS = $(SYMPHONY_ACK_FLAG) --port $(PORT)

ifneq ($(strip $(PIPELINE_ROOT)),)
RUN_ARGS += $(PIPELINE_ROOT)
endif

help:
	@echo "Targets: setup, deps, build, run, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

run: build
	./bin/symphony $(RUN_ARGS)

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

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
