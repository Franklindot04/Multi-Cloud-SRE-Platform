.DEFAULT_GOAL := help
SHELL := /bin/bash

TF_DIR := infra/terraform

.PHONY: help fmt lint validate test addons-check argocd-check apps-test apps-build apps-lint smoke-test smoke-test-stack integration-test smoke-test-integration data-up data-down data-check data-check-manifests deploy-check scripts-test docs

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

fmt: ## Format Terraform files; use CHECK=1 to only report (skips if terraform is missing)
	@if command -v terraform >/dev/null 2>&1; then \
		terraform fmt -recursive $(if $(CHECK),-check -diff,) $(TF_DIR); \
	else \
		echo "terraform not installed; skipping fmt"; \
	fi

lint: ## Lint markdown and YAML (skips tools that are not installed)
	@if command -v markdownlint-cli2 >/dev/null 2>&1; then \
		markdownlint-cli2 "**/*.md" "#node_modules"; \
	else \
		echo "markdownlint-cli2 not installed; skipping markdown lint"; \
	fi
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint .; \
	else \
		echo "yamllint not installed; skipping yaml lint"; \
	fi

validate: ## Validate every Terraform directory (skips if terraform is missing)
	@./scripts/terraform-validate.sh $(TF_DIR)

test: ## Run Terraform module tests (mocked providers, no credentials)
	@./scripts/terraform-test.sh $(TF_DIR)/modules

addons-check: ## Lint, render and schema-check the cluster add-ons (skips if helm or kubeconform is missing)
	@./scripts/addons-check.sh platform/addons

argocd-check: ## Lint, render and schema-check the Argo CD hub and its GitOps definitions (skips missing tools)
	@./scripts/argocd-check.sh platform/argocd

apps-test: ## Test the sample application services (skips a service whose toolchain is missing)
	@./scripts/apps.sh test

apps-lint: ## Lint the sample application services (go vet and gofmt, ruff, checkstyle)
	@./scripts/apps.sh lint

apps-build: ## Build the sample application container images locally (skips if Docker is missing)
	@./scripts/apps.sh build

smoke-test: ## Smoke-test an ALREADY RUNNING stack (client only; does not start or stop anything)
	@./scripts/smoke-test.sh

smoke-test-stack: ## Start the compose stack, run the smoke test, always stop the stack (logs on failure)
	@status=0; \
	docker compose -f apps/docker-compose.yml up --build -d || status=$$?; \
	if [ $$status -eq 0 ]; then ./scripts/smoke-test.sh || status=$$?; fi; \
	if [ $$status -ne 0 ]; then \
		echo "==> failed (exit $$status); container logs follow" >&2; \
		docker compose -f apps/docker-compose.yml logs --no-color >&2 || true; \
	fi; \
	docker compose -f apps/docker-compose.yml down -v --remove-orphans; \
	exit $$status

integration-test: ## Start the stack on PostgreSQL, Valkey and RabbitMQ, run integration, smoke and chaos tests, always tear down (needs apps/.env)
	@./scripts/integration-test.sh

smoke-test-integration: ## Start the integration stack, run the smoke test with --integration, always tear down (needs apps/.env)
	@./scripts/integration-test.sh --smoke

data-up: ## Start the local data layer (PostgreSQL, Valkey, RabbitMQ); needs apps/.env, copy apps/.env.example
	@test -f apps/.env || { echo "apps/.env is missing: cp apps/.env.example apps/.env and change the values" >&2; exit 1; }
	@docker compose -f apps/docker-compose.data.yml up -d

data-down: ## Stop the local data layer, keeping its volumes (PURGE=1 also removes them)
	@docker compose -f apps/docker-compose.data.yml down $(if $(PURGE),-v,)

data-check: ## Wait for the local data layer healthchecks and test each component
	@./scripts/data-check.sh

data-check-manifests: ## Lint, render and schema-check the data layer manifests (skips missing tools)
	@./scripts/data-manifests-check.sh

deploy-check: ## Lint, render, schema-check and security-check the service chart under every profile and cloud (skips missing tools)
	@./scripts/deploy-check.sh

scripts-test: ## Test the CI helper scripts (image values updater, changed-services detection)
	@./scripts/test-scripts.sh

docs: ## Check that every ADR is listed in the ADR index
	@status=0; \
	for f in docs/adr/[0-9]*.md; do \
		name=$$(basename $$f); \
		if ! grep -q "$$name" docs/adr/README.md; then \
			echo "missing from docs/adr/README.md: $$name"; \
			status=1; \
		fi; \
	done; \
	[ $$status -eq 0 ] && echo "ADR index is up to date"; \
	exit $$status
