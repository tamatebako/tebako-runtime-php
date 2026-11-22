# The build chain — architecture and invariants

This document is the normative description of how this repository's CI
turns a pristine php.net source tarball into a verified runtime pair,
and of the pin contracts that keep the skeleton honest. **If you change
any workflow, the build tooling, the matrix computation, or a cache
key, update this file in the same PR.** A future agent that skips this
file and "just fixes" a red run is the classic failure mode — read it
first. (tebako-runtime-ruby's docs/build-chain.md is the ecosystem
reference; this file carries the php skeleton's subset.)

## The staged hierarchy (skeleton shape)

One build workflow, `build-linux-gnu.yml` — tebako-runtime-python's
`_build-platform.yml` role collapsed into a single workflow (the
reusable-workflow split across `build-<platform>.yml` triggers arrives
with the second platform). Stages:

1. **compute** — the contract gate (`scripts/check_contract.rb`:
   contract.yml against `schema/contract.schema.yml`, the
   catalog ↔ versions.yml cross-lock, and the driver-source parity arm
   against the pinned link-unit release's `TEBAKO_CONTRACT_VERSION`)
   runs first; then `scripts/compute_matrix.rb` expands this platform's
   legs from `contract.yml`'s catalog × `.github/matrix.json`'s env
   vocabulary under the dispatch filters. Every downstream value flows
   from these outputs — workflow YAML never hardcodes a version, a tag,
   or a SHA.
2. **preflight** — the container digest pin (the ruby#381 idiom, born
   pinned here): `contract.yml container_digests` must equal the ghcr
   registry's CURRENT digest for the tag before any leg spends compute;
   the build leg then pulls `name:tag@digest`. A retagged toolchain
   container fails the preflight by name instead of moving the compiler
   under the matrix.
3. **build** — one leg per (php × arch): `tools/build_runtime` →
   `ci/check_symbol_provenance.sh` → `tools/boot_smoke` → the
   `runtime-packages-<os>-<arch>-<php>` artifact. The linux leg
   docker-runs the digest-pinned `tpkg-builder` image per step (the
   python factory's container grammar: the alpine-based musl image
   cannot host node actions, so the job-level `container:` form is out
   — here, and when musl arrives).
4. **verify** — the terminal aggregate and the branch-protection gate.
   The build legs are a dynamic matrix whose check names shift with the
   catalog, so protection pins this job's stable check name.

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
in preflight) and both input pins above. The named gap
(recorded-not-pinned, matching tebako-runtime-python's current shape):
the image manifest's `identity.created` is the build wall clock —
neither factory exports `SOURCE_DATE_EPOCH` yet (the ruby factory
derives one epoch from the HEAD commit and stamps every leg; adopting
that is a follow-up, tracked in README's follow-ups). The packed
image's own metadata is already deterministic: tfs-cli's mkimage falls
to epoch 0 when `SOURCE_DATE_EPOCH` is unset.

## Where each value lives (SSOT)

- Version catalog + pins: `contract.yml` (+ `schema/contract.schema.yml`).
- Source url/sha256 pins: `versions.yml` (cross-locked to the catalog
  by `scripts/check_contract.rb`).
- Env vocabulary (os/arch/host/container): `.github/matrix.json`.
- The extension policy (`CONFIGURE_ARGS`), the Makefile substitution
  anchors, the mount root: `build/lib/tebako_php_builder/php_build.rb`
  and `platform.rb`.
- The boot-contract scenarios: `tools/boot_smoke`.
- This architecture: `docs/build-chain.md`.
