# Changelog

All notable changes to W'xOps Core packages are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

> **Releases are named by date** — `release-YYYY-MM-DD` — from the first release after `v0.4.0`.
> A release name says *when*, not what is compatible. Compatibility is the XRD API version
> (`platform.wxops.cloud/v1alpha1`), held additive-only by `tests/api_compat.py`. See
> [`release-notes/README.md`](release-notes/README.md).

> This file is regenerated from git history by running `make changelog`.
> Do not edit it manually.

> Each release below links to a tag-pinned snapshot of [`docs/`](docs/) and [`development-docs/`](development-docs/)
> (API reference) and [`VERSIONS.yaml`](VERSIONS.yaml) as they existed at
> that tag — not the current `main`. Follow the links in-repo for the
> latest state.

---
## [release-2026-10-09] — 2026-10-09

### CI/CD

- **ci**: Patch installling Python deps before kcl-sync-check ([`42127f1`](https://github.com/wxops-idp/wxops-core/commit/42127f19396d68114bb86d94df7603a80823390c))
- **ci**: Rename OCI org to wxops-idp, simplify publish-packages, and refresh architecture diagram ([`08a34bc`](https://github.com/wxops-idp/wxops-core/commit/08a34bcb6cf3c22b326b7beb44fa63f5878f6e41))


### Chores

- Complete example with composite align with compositionrevision ([`b0b8e89`](https://github.com/wxops-idp/wxops-core/commit/b0b8e8949613bd5d601363664d79adde04ab3c21))
- Change ci for release-name and add rfc as docs for capture and brainstorm new idea ([`bc66861`](https://github.com/wxops-idp/wxops-core/commit/bc66861af04f4410603414c97317ea64d7999b6d))


### Documentation

- Reformat the documentation style and update outdated one ([`eb10594`](https://github.com/wxops-idp/wxops-core/commit/eb105942b1d7b6c2b5ae69c14317a74ae97cc22e))
- Add pull-request template for branch merging, and correct archiving packge for bug_report ([`3d628ce`](https://github.com/wxops-idp/wxops-core/commit/3d628cedf0c172e2312a3994aca0afdb2c23e3b5))
- Update RFC/ADR records, archive ROADMAP.md, and refresh learn docs ([`b94738b`](https://github.com/wxops-idp/wxops-core/commit/b94738b4a2d7d183cc5498fafbebab35103fc68f))
- Add rfc 006 for storageObject consideration [skip ci] ([`74ae231`](https://github.com/wxops-idp/wxops-core/commit/74ae2319477db0a4ad298f6b7ad282cfc36ca93a))


### Features

- **scm**: Add scm-connection, scm-repository and scm-oauth-app ([`b24f947`](https://github.com/wxops-idp/wxops-core/commit/b24f947156ce3984f53947b89f5b00018ae2e087))


### Refactor

- Reorganize repo layout, archive gitea-*/random-password, and migrate from terraform to opentofu in core ([`f520c85`](https://github.com/wxops-idp/wxops-core/commit/f520c85bd33bfbb89987208c4d918988be7c510b))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/release-2026-10-09/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/release-2026-10-09/VERSIONS.yaml)
🔍 [Diff vs release-2026-09-16](https://github.com/wxops-idp/wxops-core/compare/release-2026-09-16...release-2026-10-09)
## [release-2026-09-16] — 2026-09-16

### CI/CD

- **ci**: Change the package OCI location from org to project ([`b7571fa`](https://github.com/wxops-idp/wxops-core/commit/b7571fafe301c92e937e13e0a89171817c23fbf3))


### Chores

- Update claude for format the generated documentation [skip ci] ([`129809c`](https://github.com/wxops-idp/wxops-core/commit/129809c35b4316ee11b5da0851863d7961d2650b))
- Update pre-commit strategies for release to add changing of documentation [skip ci] ([`da6b105`](https://github.com/wxops-idp/wxops-core/commit/da6b105926238ded18db4eb01524439b8e0861cc))


### Documentation

- Add new and enhance research about multi-cluster and observability [skip ci] ([`7e81039`](https://github.com/wxops-idp/wxops-core/commit/7e81039d888f6f6b3a1acb5700018c160d9465cb))


### Features

- Update release machanism with new format and go oss version ([`5480944`](https://github.com/wxops-idp/wxops-core/commit/548094468efc28234bba1df4de43bb52f13f4287))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/release-2026-09-16/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/release-2026-09-16/VERSIONS.yaml)
🔍 [Diff vs 0.4.0](https://github.com/wxops-idp/wxops-core/compare/v0.4.0...release-2026-09-16)
## [0.4.0] — 2026-08-20

### CI/CD

- **ci**: Ignore main pr-validate on main and add the validation pre-commit to merge into main ([`321f5ce`](https://github.com/wxops-idp/wxops-core/commit/321f5ce9b95a7e37a42c6f3886b8940bd34c6f5d))


### Documentation

- Add research about multi-cluster for core w'xops ([`5d9f856`](https://github.com/wxops-idp/wxops-core/commit/5d9f8565f1e12985b97bd21833c24aa06b183c97))


### Features

- Add observability xtenantapp and status for whole compositions in W'xOps Core ([`532b34f`](https://github.com/wxops-idp/wxops-core/commit/532b34f572327f7ba2f3d54e5562aab218bd752c))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.4.0/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.4.0/VERSIONS.yaml)
🔍 [Full series diff (v0.3.0 → v0.4.0)](https://github.com/wxops-idp/wxops-core/compare/v0.3.0...v0.4.0)

> ⚠️ **Major/minor version bump** — this diff covers the entire **0.3.x**
> patch series (v0.3.0 through v0.3.4) so no intermediate patch is missed.
> Check [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.4.0/VERSIONS.yaml)
> for affected packages and [`docs/`](https://github.com/wxops-idp/wxops-core/tree/v0.4.0/docs)
> for schema changes.
## [0.3.4] — 2026-07-13

### Bug Fixes

- Correct the ingressRoute without calculate priority and syntax formating ([`a33a024`](https://github.com/wxops-idp/wxops-core/commit/a33a024adda3d6c62ec6c5d23a1ef73cca61e342))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.3.4/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.3.4/VERSIONS.yaml)
🔍 [Diff vs 0.3.3](https://github.com/wxops-idp/wxops-core/compare/v0.3.3...v0.3.4)
## [0.3.3] — 2026-07-13

### Bug Fixes

- Create new object IngressRoute for handle separately the header routing ([`f889f07`](https://github.com/wxops-idp/wxops-core/commit/f889f077982b426dfdc86e5c729a115567ddb3b3))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.3.3/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.3.3/VERSIONS.yaml)
🔍 [Diff vs 0.3.2](https://github.com/wxops-idp/wxops-core/compare/v0.3.2...v0.3.3)
## [0.3.2] — 2026-07-13

### Bug Fixes

- Add the priority to header routing worked ([`a159e13`](https://github.com/wxops-idp/wxops-core/commit/a159e13a91df82b5aec725b600d7075dcf04363e))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.3.2/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.3.2/VERSIONS.yaml)
🔍 [Diff vs 0.3.1](https://github.com/wxops-idp/wxops-core/compare/v0.3.1...v0.3.2)
## [0.3.1] — 2026-07-12

### Chores

- Support header routing for enhance devEx ([`0367dc1`](https://github.com/wxops-idp/wxops-core/commit/0367dc1de4a9547b64d01de217720633faffaf43))
- Update readme for latest version ([`c48d451`](https://github.com/wxops-idp/wxops-core/commit/c48d45114786f78134e4147870b96b912b6f7e6a))
- Update git-cliff for clean output when bump release version ([`a07697a`](https://github.com/wxops-idp/wxops-core/commit/a07697a634cc47fd2329cd295feb34a900553506))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.3.1/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.3.1/VERSIONS.yaml)
🔍 [Diff vs 0.3.0](https://github.com/wxops-idp/wxops-core/compare/v0.3.0...v0.3.1)
## [0.3.0] — 2026-07-10

### Features

- Support new darlane module for xtenantapp dev environment ([`5ad0e60`](https://github.com/wxops-idp/wxops-core/commit/5ad0e601f3acc72e69b090a4c037e863a2c5d65a))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.3.0/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.3.0/VERSIONS.yaml)
🔍 [Full series diff (v0.2.0 → v0.3.0)](https://github.com/wxops-idp/wxops-core/compare/v0.2.0...v0.3.0)

> ⚠️ **Major/minor version bump** — this diff covers the entire **0.2.x**
> patch series (v0.2.0 through v0.2.7) so no intermediate patch is missed.
> Check [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.3.0/VERSIONS.yaml)
> for affected packages and [`docs/`](https://github.com/wxops-idp/wxops-core/tree/v0.3.0/docs)
> for schema changes.
## [0.2.7] — 2026-06-30

### Chores

- Support gitea operation for user org and team easier modification and introduce new info phase 3 ([`30068f4`](https://github.com/wxops-idp/wxops-core/commit/30068f4ffb51bb5128b0b681682a6659c1551b06))
- Update readme and support matrix package generator ([`ecfc067`](https://github.com/wxops-idp/wxops-core/commit/ecfc067935999ceaa37b47ebb361a342db547af7))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.7/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.7/VERSIONS.yaml)
🔍 [Diff vs 0.2.6](https://github.com/wxops-idp/wxops-core/compare/v0.2.6...v0.2.7)
## [0.2.6] — 2026-06-27

### Chores

- Bump version tenant-app ([`9ddb383`](https://github.com/wxops-idp/wxops-core/commit/9ddb383a0c57169607faaf143851a45e21fa8533))
- Support raw image string for tenant-app xrds ([`d24b9c0`](https://github.com/wxops-idp/wxops-core/commit/d24b9c0b1cb1d9dc2d35b2b2abce0ba81b908e4b))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.6/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.6/VERSIONS.yaml)
🔍 [Diff vs 0.2.5](https://github.com/wxops-idp/wxops-core/compare/v0.2.5...v0.2.6)
## [0.2.5] — 2026-06-24

### Chores

- Enhance tenant-app xrds for image-pull secrets, service account and securityContext ([`dbe66ef`](https://github.com/wxops-idp/wxops-core/commit/dbe66ef3d7b8db52e3ae1d559b267c38676e0c61))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.5/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.5/VERSIONS.yaml)
🔍 [Diff vs 0.2.4](https://github.com/wxops-idp/wxops-core/compare/v0.2.4...v0.2.5)
## [0.2.4] — 2026-06-22

### Bug Fixes

- Patch the decision to provision database base on dxr and label ([`2b304fd`](https://github.com/wxops-idp/wxops-core/commit/2b304fdac1ff6b55d803b7dccf18bbaed4084b7a))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.4/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.4/VERSIONS.yaml)
🔍 [Diff vs 0.2.3](https://github.com/wxops-idp/wxops-core/compare/v0.2.3...v0.2.4)
## [0.2.3] — 2026-06-22

### Chores

- Fix error version function extra resources and bump latest version for provider and function ([`80a7d99`](https://github.com/wxops-idp/wxops-core/commit/80a7d9907d5ef1b81359ad1491026226f6046fd2))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.3/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.3/VERSIONS.yaml)
🔍 [Diff vs 0.2.2](https://github.com/wxops-idp/wxops-core/compare/v0.2.2...v0.2.3)
## [0.2.2] — 2026-06-21

### Features

- Dynamic set tier for database and platform database cluster for more usage to intent with shared or dedicated ([`82553f6`](https://github.com/wxops-idp/wxops-core/commit/82553f653007862b44c29418131042252bbc6719))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.2/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.2/VERSIONS.yaml)
🔍 [Diff vs 0.2.1](https://github.com/wxops-idp/wxops-core/compare/v0.2.1...v0.2.2)
## [0.2.1] — 2026-06-16

### CI/CD

- **ci**: Correct the regenerate changelog and add ignore for git-cliff to see regenerate ([`3286b18`](https://github.com/wxops-idp/wxops-core/commit/3286b18ae9832a5ed4f3e2b5062ab56941aa1674))


### Chores

- Attaching namespace for tenant-app applied SSO ([`c9fbfbd`](https://github.com/wxops-idp/wxops-core/commit/c9fbfbd94b01972384a822c30c4bc8fec0b4a05c))
- Regenerate changelog ([`106841b`](https://github.com/wxops-idp/wxops-core/commit/106841b89abcef7cd81102f04f4099868b409f49))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.1/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.1/VERSIONS.yaml)
🔍 [Diff vs 0.2.0](https://github.com/wxops-idp/wxops-core/compare/v0.2.0...v0.2.1)
## [0.2.0] — 2026-06-15

### CI/CD

- **ci**: Add configuration for release and bump new version on CI and Make Tools ([`dad65f0`](https://github.com/wxops-idp/wxops-core/commit/dad65f08e8e3cf570a7d67f8739e26095dffee23))
- **ci**: Add workflow for auto-update changelog.md ([`9470f73`](https://github.com/wxops-idp/wxops-core/commit/9470f73a7ab7fcdd393cad4564f3f1cc8d7fea8a))


### Features

- Release new XRDs for database and application ([`19b835c`](https://github.com/wxops-idp/wxops-core/commit/19b835c1664f820ea071210f06641b6ef5a8fd3b))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.2.0/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.0/VERSIONS.yaml)
🔍 [Full series diff (v0.1.0 → v0.2.0)](https://github.com/wxops-idp/wxops-core/compare/v0.1.0...v0.2.0)

> ⚠️ **Major/minor version bump** — this diff covers the entire **0.1.x**
> patch series (v0.1.0 through v0.1.1) so no intermediate patch is missed.
> Check [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.2.0/VERSIONS.yaml)
> for affected packages and [`docs/`](https://github.com/wxops-idp/wxops-core/tree/v0.2.0/docs)
> for schema changes.
## [0.1.1] — 2026-05-30

### Bug Fixes

- Patch the broken ci by replacing python module instead sed command ([`970625d`](https://github.com/wxops-idp/wxops-core/commit/970625d741ba905056a29e6140f9f87d3a2688fe))


### CI/CD

- **ci**: Refactor release workflow for bumping version and enhance pre-commit ([`7921ce4`](https://github.com/wxops-idp/wxops-core/commit/7921ce4bf6a61ae70e9d416139142e4097046cd3))


### Chores

- Remove default version will lead to error release with make ([`8e967a2`](https://github.com/wxops-idp/wxops-core/commit/8e967a21d581c0d1d1104e9a48d107056b499dc3))
- Fix the release bypass pip install git-cliff without python3-venv ([`513d1a9`](https://github.com/wxops-idp/wxops-core/commit/513d1a9b2cf39b97181470c9db76ace1ab96d1f9))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.1.1/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.1.1/VERSIONS.yaml)
🔍 [Diff vs 0.1.0](https://github.com/wxops-idp/wxops-core/compare/v0.1.0...v0.1.1)
## [0.1.0] — 2026-05-27

### Chores

- Fix the changelog release and automation write release-notes for new one releasing ([`a5b54f3`](https://github.com/wxops-idp/wxops-core/commit/a5b54f35e92eefb6f468c35866b144bd7254f6d9))
- Prevent error for running server-side crossplane ([`21b351d`](https://github.com/wxops-idp/wxops-core/commit/21b351d90211a407c8bf05c8cb89a71cfdd441d9))
- Change makefile for finalize the changelog workflow ([`eeca0a7`](https://github.com/wxops-idp/wxops-core/commit/eeca0a7f56c6a362042eb583461ee55ca65d4f41))
- Update and preview changelog and set the release v0.1.0 ([`4d7ffe6`](https://github.com/wxops-idp/wxops-core/commit/4d7ffe6c8564846f3cf121f72609de71b90126f6))


### Features

- Migrate core from kubebuilder into crossplane for W'xOps Controller Implementation ([`b2990b6`](https://github.com/wxops-idp/wxops-core/commit/b2990b6732e73e4cad31795757efdd72e2a061cc))
- Setup core wxops with kubebuilder to kick-off project ([`8e89719`](https://github.com/wxops-idp/wxops-core/commit/8e897194137dfc9cf2ead6d45f86646828b3517c))



📖 [API reference](https://github.com/wxops-idp/wxops-core/tree/v0.1.0/docs) · [`VERSIONS.yaml`](https://github.com/wxops-idp/wxops-core/blob/v0.1.0/VERSIONS.yaml)
---
[release-2026-10-09]: https://github.com/wxops-idp/wxops-core/releases/tag/release-2026-10-09
[release-2026-09-16]: https://github.com/wxops-idp/wxops-core/releases/tag/release-2026-09-16
[0.4.0]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.4.0
[0.3.4]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.3.4
[0.3.3]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.3.3
[0.3.2]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.3.2
[0.3.1]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.3.1
[0.3.0]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.3.0
[0.2.7]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.7
[0.2.6]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.6
[0.2.5]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.5
[0.2.4]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.4
[0.2.3]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.3
[0.2.2]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.2
[0.2.1]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.1
[0.2.0]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.2.0
[0.1.1]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.1.1
[0.1.0]: https://github.com/wxops-idp/wxops-core/releases/tag/v0.1.0
[Unreleased]: https://github.com/wxops-idp/wxops-core/compare/release-2026-10-09...HEAD

