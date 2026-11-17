.PHONY: help setup dev test check build release docker-build docker-up clean

VERSION := $(shell mix run -e 'IO.puts(Mix.Project.config()[:version])' --no-start)

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

setup: ## Install dependencies and set up the database
	mix setup

dev: ## Start the development server
	mix phx.server

test: ## Run the test suite
	mix test

check: ## Full pre-commit gate (compile, format, test)
	mix precommit

build: ## Build a production release for the current platform (Linux/macOS)
	./scripts/build_release.sh

release: build ## Alias for build

docker-build: ## Build the production Docker image
	docker build -t marsad:$(VERSION) .

docker-up: ## Start Marsad with docker-compose
	docker compose up -d

clean: ## Remove build artifacts
	rm -rf _build deps priv/static/cache_manifest.json artifacts
