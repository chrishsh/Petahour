# Run `conda activate petahour-poc` first. `make help` lists the targets.
SHELL := /bin/bash
.DEFAULT_GOAL := help

help:           ## List the commands
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | expand -t 18

build:          ## Compile the contracts
	forge build

test: test-sol test-py  ## Run every test

test-sol:       ## Solidity unit, fuzz, invariant and real-proof tests
	rm -f reports/invariant_runs.csv reports/vault_runs.csv
	forge test
	python scripts/invariant_coverage.py

test-heavy:     ## Long random-sequence run of the invariants, about five minutes
	FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-path 'test/invariant/*'

test-py:        ## Python tests, including all scenarios on a local chain
	python -m pytest tests -q

mutation:       ## Inject deliberate bugs and confirm the tests catch them (about 5 minutes)
	python scripts/mutation_check.py

demo:           ## Run all six scenarios on a local chain with live market data
	python -m petahour.cli demo

demo-offline:   ## Same, with no network access at all
	python -m petahour.cli demo --offline

demo-arbitrum:  ## Run on a local fork of live Arbitrum Sepolia
	python -m petahour.cli demo --fork arbitrum-sepolia --offline

demo-base:      ## Run on a local fork of live Base Sepolia
	python -m petahour.cli demo --fork base-sepolia --offline

demo-keep:      ## Run the demo and leave the chain up for inspection
	python -m petahour.cli demo --offline --keep

status:         ## Read protocol state from a running local chain
	python -m petahour.cli status

market:         ## Show live market data
	python -m petahour.cli market

price:          ## Reproduce the report's cost model, with live FX sensitivity
	python -m petahour.cli price

gas:            ## Gas report from the Solidity tests
	forge test --gas-report

zk:             ## Rebuild zk artifacts with a new trusted setup, then regenerate the fixture
	bash scripts/zk_build.sh
	python -m scripts.gen_fixtures

clean:          ## Remove build output (keeps zk artifacts and dependencies)
	forge clean
	rm -rf reports deployments/*.json __pycache__ .pytest_cache

.PHONY: help build test test-heavy test-sol test-py mutation demo demo-offline demo-arbitrum demo-base demo-keep status market price gas zk clean
