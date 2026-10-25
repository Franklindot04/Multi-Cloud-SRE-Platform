.DEFAULT_GOAL := help
SHELL := /bin/bash

TF_DIR := infra/terraform

.PHONY: help fmt lint validate docs

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

fmt: ## Format Terraform files (no-op if terraform is not installed)
	@if command -v terraform >/dev/null 2>&1; then \
		terraform fmt -recursive $(TF_DIR); \
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

validate: ## Validate Terraform configurations (placeholder until stacks exist)
	@if ! command -v terraform >/dev/null 2>&1; then \
		echo "terraform not installed; skipping validate"; \
	elif [ -z "$$(find $(TF_DIR) -name '*.tf' -print -quit)" ]; then \
		echo "no Terraform configuration found; nothing to validate"; \
	else \
		for dir in $$(find $(TF_DIR) -name '*.tf' -exec dirname {} \; | sort -u); do \
			echo "validating $$dir"; \
			terraform -chdir=$$dir init -backend=false -input=false >/dev/null && \
			terraform -chdir=$$dir validate || exit 1; \
		done; \
	fi

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
