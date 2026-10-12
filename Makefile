# Atalhos do desenvolvedor (08, seção 8). O `make check` roda as mesmas
# verificações do ci-infra.yml (07, seção 6), sem credenciais da AWS.
#
#   make fmt     formata o Terraform
#   make lint    tflint, shellcheck, yamllint e a higiene do repositório
#   make test    terraform validate nas raízes, terraform test do contrato e bats
#   make trace   rastreabilidade dos testes (make trace STRICT=1 para o modo estrito)
#   make check   tudo acima, com o fmt em modo de verificação

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# Raízes do Terraform (08, seção 2). Uma raiz sem arquivos .tf é pulada.
TF_ROOTS := bootstrap envs/dev envs/prod
# Testes do contrato (03, seção 6): cada run chama modules/environment com
# o provedor AWS simulado de tests/contract/mocks.
CONTRACT_TESTS := tests/contract
# Arquivos YAML: compose files das stacks e o workflow do CI.
YAML_DIRS := stacks .github
YAMLLINT_CONFIG := {extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}}}

.PHONY: help fmt fmt-check lint lint-tf lint-sh lint-yaml hygiene check-eol check-ignored check-lock test validate contract contract-envs bats trace check

help:
	@sed -n '1,9p' Makefile | sed 's/^# \{0,1\}//'

fmt:
	terraform fmt -recursive

fmt-check:
	@echo "== formatação do Terraform"
	terraform fmt -check -recursive

lint: lint-tf lint-sh lint-yaml hygiene

lint-tf:
	@echo "== tflint"
	tflint --recursive

lint-sh:
	@echo "== shellcheck"
	@files="$$(git ls-files -- 'infra' '*.sh')"; \
	if [[ -z "$$files" ]]; then echo "nenhum script versionado"; else echo "$$files" | xargs shellcheck; fi

lint-yaml:
	@echo "== yamllint"
	@dirs=""; for d in $(YAML_DIRS); do [[ -d "$$d" ]] && dirs="$$dirs $$d"; done; \
	files="$$(find $$dirs -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null || true)"; \
	if [[ -z "$$files" ]]; then echo "nenhum arquivo YAML"; else yamllint -s -d '$(YAMLLINT_CONFIG)' $$files; fi

# Higiene do repositório (07, seção 6; 08, seções 5.1 e 6; G3, G12 e G14).
hygiene: check-eol check-ignored check-lock

check-eol:
	@echo "== finais de linha (sem CRLF)"
	@bad="$$(git ls-files --eol | awk '$$1 == "i/crlf" || $$1 == "i/mixed" || $$2 == "w/crlf" || $$2 == "w/mixed" { sub(/^.*\t/, ""); print }')"; \
	if [[ -n "$$bad" ]]; then \
	  echo "ERRO: arquivos com finais de linha CRLF (08, seção 5.1). Converta para LF (por exemplo, com dos2unix) e confira o .gitattributes:"; \
	  echo "$$bad" | sed 's/^/  - /'; exit 2; \
	fi; echo "ok"

check-ignored:
	@echo "== arquivos ignorados versionados"
	@bad="$$(git ls-files -ci --exclude-standard)"; \
	if [[ -n "$$bad" ]]; then \
	  echo "ERRO: arquivos que o .gitignore exclui estão versionados (08, seção 6). Remova-os do Git com 'git rm --cached':"; \
	  echo "$$bad" | sed 's/^/  - /'; exit 2; \
	fi; echo "ok"

check-lock:
	@echo "== .terraform.lock.hcl versionado"
	@if git check-ignore -q --no-index .terraform.lock.hcl; then \
	  echo "ERRO: o .gitignore exclui o .terraform.lock.hcl, que deve ser versionado (08, seções 4.1 e 6)."; exit 2; \
	fi; \
	missing=""; for r in $(TF_ROOTS); do \
	  if compgen -G "$$r/*.tf" >/dev/null && ! git ls-files --error-unmatch "$$r/.terraform.lock.hcl" >/dev/null 2>&1; then missing="$$missing $$r"; fi; \
	done; \
	if [[ -n "$$missing" ]]; then \
	  echo "ERRO: raízes do Terraform sem .terraform.lock.hcl versionado:$$missing. Rode 'terraform init' na raiz e faça 'git add' do lock."; exit 2; \
	fi; echo "ok"

test: validate contract contract-envs bats

# Usa uma pasta de dados temporária (TF_DATA_DIR) para não depender nem mexer
# no .terraform/ que o infra inicializou com o backend real e credenciais.
validate:
	@echo "== terraform validate"
	@for r in $(TF_ROOTS); do \
	  if compgen -G "$$r/*.tf" >/dev/null; then \
	    echo "-- $$r"; \
	    d="$$(mktemp -d)"; \
	    TF_DATA_DIR="$$d" terraform -chdir="$$r" init -backend=false -input=false >/dev/null; \
	    rc=0; TF_DATA_DIR="$$d" terraform -chdir="$$r" validate || rc=$$?; \
	    rm -rf "$$d"; [[ $$rc -eq 0 ]] || exit $$rc; \
	  else echo "-- $$r: sem arquivos .tf, pulado"; fi; \
	done

contract:
	@echo "== terraform test (contrato)"
	@if compgen -G "$(CONTRACT_TESTS)/*.tftest.hcl" >/dev/null; then \
	  terraform -chdir="$(CONTRACT_TESTS)" init -backend=false -input=false >/dev/null; \
	  terraform -chdir="$(CONTRACT_TESTS)" test -test-directory=.; \
	else echo "sem testes do contrato ainda"; fi

# Valores de cada envs/<env>/terraform.tfvars contra o contrato (C10). As
# variáveis sem padrão ainda em branco ("") recebem um marcador só para este
# teste, porque o plan as exige apenas a partir da E4a (03, seção 3.8).
TFVARS_PLACEHOLDERS := dockerhub_namespace=marcador db_schema_repo_url=https://example.invalid/marcador.git db_schema_ref=marcador db_schema_path=marcador.sql

contract-envs:
	@echo "== terraform test (terraform.tfvars dos ambientes)"
	@terraform -chdir="$(CONTRACT_TESTS)/envs" init -backend=false -input=false >/dev/null
	@for e in dev prod; do \
	  f="envs/$$e/terraform.tfvars"; \
	  [[ -f "$$f" ]] || { echo "-- $$e: sem terraform.tfvars, pulado"; continue; }; \
	  args=(-var-file="../../../$$f"); \
	  for kv in $(TFVARS_PLACEHOLDERS); do \
	    k="$${kv%%=*}"; \
	    if grep -Eq "^[[:space:]]*$$k[[:space:]]*=[[:space:]]*\"\"" "$$f"; then args+=(-var="$$kv"); fi; \
	  done; \
	  echo "-- $$e"; \
	  terraform -chdir="$(CONTRACT_TESTS)/envs" test -test-directory=. "$${args[@]}"; \
	done

bats:
	@echo "== bats"
	@if compgen -G "tests/shell/*.bats" >/dev/null; then bats tests/shell; else echo "sem testes bats"; fi

trace:
	@echo "== rastreabilidade"
	scripts/check-traceability.sh $(if $(STRICT),--strict)

check: fmt-check lint test trace
	@echo "make check: tudo certo"
