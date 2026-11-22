# AGENTS.md — tebako-runtime-php

The binding rules are the ecosystem's: **tamatebako/AGENTS.md** (the
workspace root) — read it first. The short version as applied here:

- **Draft PRs only.** No merges to `main`, no tags, no releases without
  the owner's explicit go-ahead.
- **Prebuilt artifacts flow downward.** This factory CONSUMES published
  artifacts — php.net source tarballs (sha256-pinned in
  `versions.yml`) and the link unit + tfs CLI from the pinned
  tamatebako/tebako release (`contract.yml`). Never a source checkout
  of a sibling repo, in CI or locally; never a source build of the
  driver stack.
- **SSOT for versions and pins.** Versions, tags, SHAs live in
  `contract.yml` (catalog + pins), `versions.yml` (source url/sha256),
  and `.github/matrix.json` (env vocabulary) — never hardcoded in
  workflow YAML or scripts.
- **No php source patches.** The tarball ships pristine; the driver
  link is a build-time substitution on the GENERATED Makefile
  (`build/lib/tebako_php_builder/php_build.rb`). A genuine php source
  need means a tamatebako source factory, not a factory-side hot-patch.
- **YAML** for all authored config/manifests; named errors and named
  exit codes, never silent fallbacks.

## Repo status: pre-release

`tools/build_runtime` is implemented (the tebako-runtime-python
`build/lib` port): fetch/verify → configure/make → driver link →
env-image pack → packaging → sidecars, gated by
`ci/check_symbol_provenance.sh` and `tools/boot_smoke`. CI carries three
platform workflows (`build-linux-gnu.yml`, `build-linux-musl.yml`,
`build-macos.yml` — thin triggers over `_build-platform.yml`: parity →
compute → preflight → build → publish → verify) plus the static gate
(`lint.yml`). The publish pipeline (`publish.yml` + the tebako-release
gem via `scripts/release_adapter.rb` + `tools/registry_update.rb`) is
present and dispatch-proven, but **no release has been cut** — the first
release is the owner's explicit act (README's status block names the
remaining increments).

## Repo-local gotchas

- Tooling is **Ruby** (stdlib-first; gems only via `Gemfile`).
  Ecosystem §12 rules apply: autoload only, no `require_relative`, no
  `send`/`instance_variable_get`/`respond_to?` metaprogramming.
- `Gemfile.lock` is gitignored (factory convention — resolutions float).
- `contract.yml` is validated by `scripts/check_contract.rb` against
  `schema/contract.schema.yml` (`bundle exec`), including the
  driver-source parity arm (contract.yml ↔ the pinned link-unit
  release's compiled-in `TEBAKO_CONTRACT_VERSION`). A contract bump
  edits both in the same commit.
- CI containers are `ghcr.io/tamatebako/tpkg-builder-*`
  (tebako-ci-containers) only, pulled `name:tag@digest`; the archived
  v1 `tebako-<platform>` images are never referenced here.
- The container legs bind-mount the workspace and run as root —
  root-owned files land in `.build/` and `runtime-packages/`. The
  workflow hands them back to the runner user (`chown` at the end of
  the docker-run step); do the same locally before editing or
  `git clean`-ing.
- Local container builds need docker with the linux/amd64 platform
  (`docker run --platform linux/amd64` on arm64 hosts).
- `gh pr create` bodies: always `--body-file` — inline `--body` with
  backticks executes them (ecosystem §13).
- Architecture/chain questions: `docs/build-chain.md` first, then
  README.md. If you change a workflow, the build tooling, the matrix,
  or a cache key, update `docs/build-chain.md` in the same PR.
