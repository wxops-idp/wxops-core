REGISTRY ?= ghcr.io/wxops-idp/wxops-core

# datreeio CRDs-catalog ref used for third-party schema lookups. PINNED on
# purpose: tracking `main` would let upstream change what CI accepts with no
# commit in this repo, making the gate non-reproducible. Bump alongside the
# reference stack in CLAUDE.md. Keep in sync with CATALOG_REF in tests/structural.py.
CRDS_CATALOG_REF ?= 52b0261318acc7dd0b66e032759b1f218216b980

# How long `make providers-packages` / `make providers-config` wait for packages to install and their APIs to
# appear. Pulling several provider images on a cold cluster is the slow part.
WAIT_TIMEOUT ?= 300s

# providers/ is four categories, each its own kustomization (providers/<category>/kustomization.yaml). The order is the
# install order. providers/archive/ is excluded on purpose: archived manifests are not applied.
PROVIDER_CATEGORIES := functions packages rbac config

# Package names and directories both come from VERSIONS.yaml via tests/lib/packages.py —
# the one resolver (ADR-002 groups, RFC-007 layout). Adding a package is a VERSIONS.yaml edit.
PACKAGES := $(shell python3 tests/lib/packages.py list)
PACKAGE_PAIRS := $(shell python3 tests/lib/packages.py pairs)

# ── Package build & publish ──────────────────────────────────────────────────

.PHONY: build
build: ## Build all Crossplane OCI packages locally (.xpkg files)
	@for pair in $(PACKAGE_PAIRS); do \
		pkg=$${pair%%=*}; dir=$${pair#*=}; \
		echo "→ building $$dir"; \
		crossplane xpkg build \
			-f $$dir \
			-o $$pkg.xpkg \
			--ignore kustomization.yaml; \
	done

.PHONY: push
push: build ## Build and push all packages to the registry
	@for pkg in $(PACKAGES); do \
		echo "→ pushing $$pkg:$(VERSION)"; \
		crossplane xpkg push \
			$(REGISTRY)/$$pkg:$(VERSION) \
			-f $$pkg.xpkg; \
	done

.PHONY: validate
validate: ## Validate all package directories (crossplane xpkg build, no push)
	@bash .github/scripts/validate-packages.sh

.PHONY: clean
clean: ## Remove local .xpkg build artifacts
	rm -f *.xpkg

# ── KCL source management ────────────────────────────────────────────────────

.PHONY: kcl-sync
kcl-sync: ## Embed kcl/{pkg}/main.k into composition.yaml (run after editing KCL source)
	@python3 .github/scripts/kcl-sync.py

.PHONY: kcl-check
kcl-check: ## Fail if any composition.yaml is out of sync with its kcl/ source
	@python3 .github/scripts/kcl-sync.py --check

.PHONY: readme-sync
readme-sync: ## Regenerate the README.md packages table from VERSIONS.yaml
	@python3 .github/scripts/gen-readme-packages.py

.PHONY: readme-check
readme-check: ## Fail if README.md packages table is out of sync with VERSIONS.yaml
	@python3 .github/scripts/gen-readme-packages.py --check

# ── Lint ────────────────────────────────────────────────────────────────────

.PHONY: lint
lint: ## YAML lint + kubeconform schema validation
	@echo "→ yamllint"
	@yamllint -c .yamllint.yaml .
	@echo "→ kubeconform (package/)"
	@find package/ -name '*.yaml' | xargs kubeconform \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/$(CRDS_CATALOG_REF)/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		-ignore-missing-schemas \
		-summary

# ── Tests ────────────────────────────────────────────────────────────────────
# Offline. No cluster required — `crossplane composition render` runs the real
# function images in Docker. See tests/README.md for what this can and cannot
# catch; notably it cannot catch provider RBAC gaps.

PYTHON ?= python3

.PHONY: test
test: test-xrd test-api-compat test-golden test-invariants ## Run the offline test suite (the merge gate)
	@echo ""
	@echo "test suite passed"

.PHONY: test-xrd
test-xrd: ## Strict: XRs conform to our XRDs; negative cases are rejected
	@$(PYTHON) tests/xrd.py

.PHONY: test-golden
test-golden: ## Golden render tests — output vs committed expectations
	@$(PYTHON) tests/golden.py

.PHONY: test-invariants
test-invariants: ## Rules that must hold for every package and case
	@$(PYTHON) tests/invariants.py

.PHONY: test-api-compat
test-api-compat: ## Released API stays additive — schema diff, XR replay, golden resource checks vs last release
	@$(PYTHON) tests/api_compat.py
	@$(PYTHON) tests/api_compat.py --self-test

.PHONY: test-structural
test-structural: ## Best-effort third-party schema filter (NOT in `make test`)
	@$(PYTHON) tests/structural.py

.PHONY: test-update
test-update: ## Regenerate goldens after an intentional composition change
	@$(PYTHON) tests/golden.py --update

.PHONY: test-deps
test-deps: ## Install the test suite's Python dependencies
	@pip install -r tests/requirements.txt

# ── Cluster install ───────────────────────────────────────────────────────────

# providers/ is installed in four steps, in this order, each a target of its own so one category can be applied, re-applied or debugged alone:
#   functions → packages (waits Installed + Healthy) → rbac → config (waits for each ProviderConfig API to be served).
# A GitOps engine needs none of this: `kubectl apply -k providers/` is the all-at-once view and Argo CD / Flux retry until it settles.

.PHONY: providers
providers: providers-check ## Install functions, provider packages, RBAC and ProviderConfigs, in order, waiting where it must
	@$(MAKE) --no-print-directory providers-functions providers-packages providers-rbac providers-config

.PHONY: providers-check
providers-check: ## Check every manifest in providers/<category>/ is listed in that category's kustomization
	@# `kubectl apply -k` applies only what is listed, so an unlisted file would be silently skipped.
	@for d in $(PROVIDER_CATEGORIES); do \
		grep -qE "^[[:space:]]+- $$d$$" providers/kustomization.yaml || \
			{ echo "error: providers/$$d is not listed in providers/kustomization.yaml" >&2; exit 1; }; \
		for f in providers/$$d/*.yaml; do \
			b=$$(basename "$$f"); [ "$$b" = kustomization.yaml ] && continue; \
			grep -qE "^[[:space:]]+- $$b([[:space:]]|$$)" "providers/$$d/kustomization.yaml" || \
				{ echo "error: providers/$$d/$$b is not listed in providers/$$d/kustomization.yaml — kubectl apply -k would skip it" >&2; exit 1; }; \
		done; \
	done

.PHONY: providers-functions
providers-functions: providers-check ## Install the Crossplane Functions, wait until healthy
	@echo "→ installing functions"
	kubectl apply -k providers/functions
	@kubectl wait --for=condition=Healthy function.pkg.crossplane.io --all --timeout=$(WAIT_TIMEOUT)

.PHONY: providers-packages
providers-packages: providers-check ## Install the Provider packages and their runtime config, wait until installed and healthy
	@echo "→ installing provider packages (WAIT_TIMEOUT=$(WAIT_TIMEOUT))"
	kubectl apply -k providers/packages
	@kubectl wait --for=condition=Installed provider.pkg.crossplane.io --all --timeout=$(WAIT_TIMEOUT)
	@kubectl wait --for=condition=Healthy provider.pkg.crossplane.io --all --timeout=$(WAIT_TIMEOUT)

.PHONY: providers-rbac
providers-rbac: providers-check ## Apply the static RBAC: the provider's grants and the persona / Platform API roles
	@echo "→ applying RBAC"
	kubectl apply -k providers/rbac

.PHONY: providers-config
providers-config: providers-check ## Apply the ProviderConfigs, once each provider's API is served (after providers-packages)
	@# The CRD names come from the manifests themselves, so a new provider needs no edit here.
	@echo "→ waiting for the ProviderConfig APIs to be served"
	@for group in $$(grep -h '^apiVersion:' providers/config/providerconfig-*.yaml | cut -d' ' -f2 | cut -d/ -f1 | sort -u); do \
		echo "    providerconfigs.$$group"; \
		kubectl wait --for=condition=Established "crd/providerconfigs.$$group" --timeout=$(WAIT_TIMEOUT) >/dev/null; \
	done
	@echo "→ applying ProviderConfigs"
	kubectl apply -k providers/config

.PHONY: provider-configs
provider-configs: providers-config ## Alias of providers-config

.PHONY: install
install: ## Install all packages from registry (production)
	kubectl apply -k package/

.PHONY: uninstall
uninstall: ## Remove all registry-installed Configuration resources
	kubectl delete -k package/ --ignore-not-found

.PHONY: install-dev
install-dev: ## Apply XRDs and Compositions directly — no registry needed (development)
	kubectl apply -k package/dev/

.PHONY: uninstall-dev
uninstall-dev: ## Remove directly applied XRDs and Compositions
	kubectl delete -k package/dev/ --ignore-not-found

# ── Changelog ────────────────────────────────────────────────────────────────

.PHONY: changelog
changelog: ## Regenerate CHANGELOG.md from full git history (requires git-cliff)
	@which git-cliff > /dev/null || (echo "git-cliff not installed — see https://git-cliff.org/docs/installation" && exit 1)
	git-cliff -o CHANGELOG.md

.PHONY: changelog-preview
changelog-preview: ## Preview unreleased changelog without writing
	@which git-cliff > /dev/null || (echo "git-cliff not installed — see https://git-cliff.org/docs/installation" && exit 1)
	git-cliff --unreleased --strip all

# ── Release ───────────────────────────────────────────────────────────────────
# A release is named by the day it is cut — release-YYYY-MM-DD (UTC), .2 for a
# second one that day. Compatibility is not carried by the name: it is the XRD
# API version, held additive-only by tests/api_compat.py. See
# release-notes/README.md.

.PHONY: release-notes
release-notes: ## Scaffold release-notes/<release>.md with its compatibility report (VERSION defaults to today)
	@ver="$(VERSION)"; [ -n "$$ver" ] || ver=$$(python3 .github/scripts/release-state.py next); \
	echo "$$ver" | grep -qE '^release-[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$$' || \
		{ echo "error: VERSION must look like release-YYYY-MM-DD[.N], e.g. make release-notes VERSION=release-2026-09-11" >&2; exit 1; }; \
	bash .github/scripts/check-release-notes.sh "$$ver"

.PHONY: release-check
release-check: ## Fail if VERSIONS.yaml and package/install/ disagree
	@python3 .github/scripts/release-state.py check

# The release commit skips the test-api-compat hook: `release-state.py write`
# has just run that same gate on this exact tree, and rerunning it after the
# allowlist is cleared would re-fail every break the allowlist permitted.
.PHONY: release
release: ## Prepare a release commit + tag (no push) — VERSION=release-YYYY-MM-DD[.N] (default: today, UTC) | ALL=1 rebuilds every package
	@which git-cliff > /dev/null || (echo "git-cliff not installed — see https://git-cliff.org/docs/installation" && exit 1)
	@echo ""
	@echo "  README.md, docs/, development-docs/ and release-notes/ get staged and"
	@echo "  committed together with CHANGELOG.md below — go update whatever's"
	@echo "  drifted before this runs, or right now in another terminal, since"
	@echo "  nothing else in the tree may be dirty (see the check below)."
	@echo ""
	@ver="$(VERSION)"; [ -n "$$ver" ] || ver=$$(python3 .github/scripts/release-state.py next); \
	all=""; [ -z "$(ALL)" ] || all="--all"; \
	echo "$$ver" | grep -qE '^release-[0-9]{4}-[0-9]{2}-[0-9]{2}(\.[0-9]+)?$$' \
		|| { echo "error: '$$ver' is not a release name (expected release-YYYY-MM-DD[.N])" >&2; exit 1; }; \
	dirty=$$(git status --porcelain -- . ':!README.md' ':!docs' ':!development-docs' ':!release-notes' ':!CHANGELOG.md'); \
	[ -z "$$dirty" ] \
		|| { echo "error: working tree has uncommitted changes outside README.md/docs/development-docs/release-notes/CHANGELOG.md — commit or stash before releasing:" >&2; echo "$$dirty" >&2; exit 1; }; \
	git rev-parse -q --verify "refs/tags/$$ver" >/dev/null \
		&& { echo "error: tag $$ver already exists" >&2; exit 1; }; \
	echo "→ classifying changes and pinning packages for $$ver"; \
	python3 .github/scripts/release-state.py write "$$ver" $$all || exit 1; \
	python3 .github/scripts/gen-readme-packages.py; \
	echo "→ writing CHANGELOG.md for $$ver"; \
	git-cliff --tag "$$ver" -o CHANGELOG.md; \
	git add CHANGELOG.md README.md docs/ development-docs/ release-notes/ \
		VERSIONS.yaml package/install/ tests/api-compat-allow.yaml; \
	if git diff --cached --quiet; then \
		echo "→ nothing to commit for $$ver — no package pins, notes or docs changed"; \
	else \
		echo "→ staged for $$ver:"; \
		git diff --cached --name-only | sed 's/^/    /'; \
		SKIP=no-commit-to-branch,test-api-compat git commit -m "chore(release): prepare for release $$ver"; \
	fi; \
	echo "→ tagging $$ver"; \
	git tag "$$ver"; \
	echo ""; \
	echo "✓ Release $$ver prepared locally."; \
	echo "  Review with: git log -2 --stat"; \
	echo ""; \
	echo "  Publish when ready:"; \
	echo "    git push origin main"; \
	echo "    git push origin $$ver"

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
