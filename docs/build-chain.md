# The build chain — architecture and invariants

This document is the normative description of how this repository's CI
turns a pristine php.net source tarball into a verified runtime pair,
and of the pin contracts that keep the skeleton honest. **If you change
any workflow, the build tooling, the matrix computation, or a cache
key, update this file in the same PR.** A future agent that skips this
file and "just fixes" a red run is the classic failure mode — read it
first. (tebako-runtime-ruby's docs/build-chain.md is the ecosystem
reference; this file carries the php skeleton's subset.)

## The staged hierarchy

One reusable workflow, `_build-platform.yml` (tebako-runtime-python's
port), called by the three thin triggers (`build-linux-gnu.yml`,
`build-linux-musl.yml`, `build-macos.yml`) and by the `publish.yml`
coordinator. Stages:

1. **parity** — the contract gate's driver-source parity arm needs the
   pinned link-unit release's `lib.rs` off raw.githubusercontent.com, a
   fetch that flakes under near-simultaneous per-platform reads
   (tamatebako/tebako-runtime-python#4). ONE job fetches it (bounded
   retry) and hands it to compute as an artifact.
2. **compute** — the contract gate (`scripts/check_contract.rb`:
   contract.yml against `schema/contract.schema.yml`, the
   catalog ↔ versions.yml cross-lock, and the parity arm reading the
   stage-1 artifact via `TEBAKO_DRIVER_SRC`) runs first; then
   `scripts/compute_matrix.rb` expands this platform's legs from
   `contract.yml`'s catalog × `.github/matrix.json`'s env vocabulary
   under the dispatch filters. Every downstream value flows from these
   outputs — workflow YAML never hardcodes a version, a tag, or a SHA.
   The run's `SOURCE_DATE_EPOCH` (the HEAD commit's epoch, the ruby#381
   idiom) is computed here and exported to every leg.
3. **preflight** — the container digest pin (the ruby#381 idiom, born
   pinned here): `contract.yml container_digests` must equal the ghcr
   registry's CURRENT digest for the tag — per (container × leg arch) —
   before any leg spends compute; the build leg then pulls
   `name:tag@digest`. A retagged toolchain container fails the preflight
   by name instead of moving the compiler under the matrix, and a failed
   preflight skips the build legs outright.
4. **build** — one leg per (php × arch): `tools/build_runtime` → the
   macOS sign+notarize arm (spec 31; `ci/macos-sign-notarize-runtime.sh`,
   gated on `APPLE_SIGNING_ENABLED`, before the gates so every hash
   anchors the SIGNED bytes) → `ci/check_symbol_provenance.sh` →
   `tools/boot_smoke` → the `runtime-packages-<os>-<arch>-<php>`
   artifact. The linux legs docker-run the digest-pinned `tpkg-builder`
   image per step (the python factory's container grammar: the
   alpine-based musl image cannot host node actions, so the job-level
   `container:` form is out); the macos legs are runner-native.
5. **publish** — only when the caller asked (`publish: true`): the leg
   that built a package publishes it and signs its served names from its
   OWN job (spec 13 §2a's de-rendezvous; the tebako-release gem's
   uploader + signer), then attests SLSA L3 provenance. A publish-layer
   failure re-runs as a minutes-long download + upload, never a rebuild
   (tebako-runtime-ruby#190).
6. **verify** — the terminal aggregate and the branch-protection gate.
   The build legs are a dynamic matrix whose check names shift with the
   catalog, so protection pins this job's stable check name; on publish
   runs the gate depends on the publish legs too.

`publish.yml` is the operator-facing coordinator (dispatch only):
three platform fan-outs over `_build-platform.yml`, the `force_rebuild`
release-object recreation (tebako-runtime-ruby#189), and the ONE release
job — the whole-matrix audit (the gem under `AUDIT_ONLY`), the registry
render (`tools/registry_update.rb`), and the registry bot PR. `publish`
defaults to **false**: publishing is an explicit operator act.

`lint.yml` is the static gate (no builds): the same contract check, the
catalog/matrix resolution, a `ruby -c` sweep over every authored ruby
file, and a parse pass over every authored YAML/JSON.

## The inputs (both pinned, both verified)

- **php source** — `www.php.net/distributions/php-<v>.tar.gz`,
  sha256-pinned per version in `versions.yml`. There is NO tamatebako
  php source factory; the tarball is upstream's pristine release.
  `SourceFetcher` downloads and verifies; a checksum mismatch is a
  named error, never a re-fetch.
- **the link unit** — `link-unit-<ver>-<pid>.tar.gz` from the pinned
  tamatebako/tebako release (`contract.yml link_unit_release`), fetched
  through the ruby factory's `ci/link-unit-download.sh` digest-anchor
  idiom: the release's own SHA256SUMS is the trust anchor, and the
  tfs CLI comes from the same pinned release. An empty pin, a missing
  asset, or a checksum mismatch are hard named errors — this factory
  has no source-build path for the driver stack.

Both download under `.build/downloads/` and are re-verified against the
pins on every use, so a poisoned or stale cache entry cannot survive a
pin bump.

## The Makefile-substitution law (the factory never edits php C source)

This repo is a **pure builder** of pristine upstream source. The driver
link is composed by build-time substitutions on php's GENERATED
`Makefile` (`PhpBuild#substitute_makefile`), never by a source patch:

- `sapi/cli/php_cli.lo`'s compile recipe gains `-Dmain=php_cli_main`
  (the interpreter's entry point renamed at compile time);
- `BUILD_CLI`'s link recipe gains `sapi/cli/tebako_php_main.o
  $(TEBAKO_LIBS)`;
- the `$(SAPI_CLI_PATH)` rule gains the fs TU object as a prerequisite,
  and the fs TU compile rule + the `TEBAKO_LIBS` variable land under a
  marker comment.

Every anchor must match exactly once; a php release whose
generated-Makefile grammar drifted is a named build error (exit 103),
never a half-applied edit. The substitution also removes the stale
`php_cli` objects it invalidates (make does not track recipe changes).

If a genuine php source need ever appears (a patch the runtime cannot
live without), the answer is a tamatebako **source factory** for php —
the tamatebako/ruby and tamatebako/python pattern — never a factory-
side hot-patch of php C source. Do not resurrect the incident-era
pattern the ruby factory's build-chain doc names.

## The cache architecture

One cache, keyed on what it contains:

| Cache | Key | Contents |
|-------|-----|----------|
| downloads + staged link unit | `tebako-php-dl-<os>-<arch>-<hash(contract.yml, versions.yml)>-v<CACHE_VER>` | `.build/downloads` (the sha256-verified tarballs + tfs CLI) and `.build/link-unit` (the staged unit) |

`save-always: true` — a red boot smoke must never tax the next leg a
cold re-download. The key carries the pins' hashes, so a pin bump mints
a fresh entry and the stale one ages out. `CACHE_VER` stays the manual
escape hatch — bump ONLY for a build-recipe shape change under
UNCHANGED pins, and say why in the workflow comment.

## The determinism notes

Born pinned: the toolchain container digests (recorded == live proven
in preflight) and both input pins above. `SOURCE_DATE_EPOCH` follows
the ruby#381 idiom: the compute job derives ONE epoch from the HEAD
commit (`git log -1 --format=%ct` under a full-history checkout) and
every leg stamps it into the image manifest's `identity.created`
(`ImageManifest` honors it; unset falls to epoch 0), so a same-commit
re-run stamps identically. The packed image's own metadata is
deterministic the same way (tfs-cli's mkimage honors the variable).

The optimization-flags honesty pair (tebako-runtime-python#79's
lesson, php-shaped): the gnu tpkg-builder container exports
`CFLAGS=-pthread`, and php's autoconf lets an environment CFLAGS
REPLACE its `-g -O2` default (CPython is immune — its optimization
flags ride a separate `OPT`) — the skeleton's first gnu builds shipped
an UNOPTIMIZED interpreter green under a boot-only gate. php records
no CFLAGS at runtime (`php -i` exposes only the Configure Command and
the Debug Build row), so the guard is two-sided: `PhpBuild#configure_env`
pins `CFLAGS=-O2 -pthread` explicitly on linux-gnu (the container's
export no longer decides the flags), `PhpBuild#recorded_cflags` reads
the ACTUAL flags back from the generated Makefile and fails the build
(exit 103) unless an `-O2`/`-O3` is present and no `-O0/-O1/-Og/-Od`
is, and the boot smoke's compute-floor scenario re-asserts the pair at
run time (the `.contract.yaml` card's `built_from.cflags` — the one
surface that records the flags — plus a fib(35) timing tripwire).

## Where each value lives (SSOT)

- Version catalog + pins (including `container_digests`,
  `macos_deployment_target`, `release_tooling`): `contract.yml`
  (+ `schema/contract.schema.yml`).
- Source url/sha256 pins: `versions.yml` (cross-locked to the catalog
  by `scripts/check_contract.rb`).
- Env vocabulary (os/arch/host/container): `.github/matrix.json`.
- The extension policy (`CONFIGURE_ARGS`), the Makefile substitution
  anchors, the mount root, the flags honesty pair: `build/lib/tebako_php_builder/php_build.rb`
  and `platform.rb`.
- The release machinery (publish/sign/audit): the tebako-release gem at
  `contract.yml`'s `release_tooling` tag (tamatebako/tebako-release-tooling
  is the single owner); this repo carries only its identity + policy in
  `scripts/release_adapter.rb`.
- The boot-contract scenarios: `tools/boot_smoke`.
- This architecture: `docs/build-chain.md`.
