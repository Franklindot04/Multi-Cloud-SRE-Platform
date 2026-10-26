.DEFAULT_GOAL := help
SHELL := /bin/bash

TF_DIR := infra/terraform

.PHONY: help fmt lint validate test addons-check argocd-check docs

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
