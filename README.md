# tebako-runtime-php

Builds the prebuilt tebako php runtime packages
(`tebako-runtime-<tebako-version>-php-<php-version>-<triplet>[.exe]`) that
the tebako bootstrap/shim resolves at press/run time. Modeled on
[tebako-runtime-python](https://github.com/tamatebako/tebako-runtime-python)
(itself on
[tebako-runtime-ruby](https://github.com/tamatebako/tebako-runtime-ruby)).

The package-name spelling carries the `php` language segment from the
first build — the [tebako#716](https://github.com/tamatebako/tebako/issues/716)
spelling, with **no era gate**: this factory was born after the lang-ful
spelling landed (the node factory's rationale), so no immutable
lang-less line exists to stay compatible with.

**Status: pre-release.** The chain — fetch/verify → configure/make →
driver link → env-image pack → packaging → provenance gate → boot smoke
— is implemented in `build/lib/tebako_php_builder/` and wired into three
platform workflows (`build-linux-gnu.yml`, `build-linux-musl.yml`,
`build-macos.yml` — thin triggers over `_build-platform.yml`), covering
linux-gnu x86_64, linux-musl x86_64 + arm64 (digest-pinned tpkg-builder
containers), and macos x86_64 + arm64 (runner-native, with the spec 31
sign+notarize arm gated on `APPLE_SIGNING_ENABLED`). The boot smoke
carries the compute-floor scenario (php `-i` flags + the contract card's
recorded CFLAGS + a fib(35) timing tripwire — tebako-runtime-python#79's
port, warn-tiered on macos x86_64 while tebako#1095 is live). The publish
pipeline is present and dispatch-proven — `publish.yml` (the python
factory's coordinator port: per-leg publish+sign via the tebako-release
gem, SLSA attest, `.manifest.json` shards, registry render) — but **no
release has been cut**: every increment stays draft-PR-only until the
whole chain is green end-to-end (the owner's rule). What is missing,
each its own increment: the first real release, the windows leg (needs
the spec 17 §7 materialize tier branches in the fs TU), the extension
breadth + composer lane (the census's payload scenarios), the
hello-runtimes arm, the php.net release monitor, and the boot-contract
parity `spec/` suite.

## The driver is linked into the interpreter, not wrapped

php runtimes ship the spec-17 driver **linked into the `php` cli
executable** (the ruby/python pattern), not the java-style wrapper exe
(spec 29).

Rationale:

- The wrapper pattern exists for runtimes that arrive as third-party
  binaries we cannot relink (openjdk). php here is **source-built by
  us** — this factory fetches the pristine, sha256-pinned php.net
  release tarballs and compiles them — so the link step is ours, and
  the driver goes inside the exe: one process, no wrapper layer, no
  second argv/env contract.
- The boot/exit-code contract is then *literally* the ruby driver's:
  `TEBAKO_RUNTIME_IMAGE` handoff, `TEBAKO_MOUNT_ROOT` redirect with
  exit 65 (malformed) / 78 (ungranted), the same named errors.
- Contract 2 from day one: this factory has no contract-1 era (no
  merged env+app images, no embedded incbin image). The env image is
  always the standalone `.tfs` the driver mounts from
  `TEBAKO_RUNTIME_IMAGE`.

The link mechanism is build-time substitution on php's **generated
Makefile**, never a source patch (the python factory's Makefile.pre
analog): the `php_cli.lo` compile recipe gains `-Dmain=php_cli_main`
(the interpreter's entry point is renamed at compile time — `main`
occurs in `sapi/cli/php_cli.c` exactly once as the function definition;
the remaining occurrences are a string literal and an include filename,
where a macro never expands), the `BUILD_CLI` link recipe gains the fs
TU object + `$(TEBAKO_LIBS)` (the scoped driver + tfs + the native
closure, Mlibs), and the fs TU's compile rule lands under a marker
comment. Every anchor must match exactly once — a php release whose
generated-Makefile grammar drifted is a named build error (exit 103),
never a half-applied edit.

## The unpatched interpreter: preload shim + re-exec

The architectural difference from ruby: no tamatebako php source
factory exists, so this factory fetches **pristine php.net tarballs** —
php's own libc file IO cannot see the driver's mounts (ruby carries
patch literals that reroute its IO; php does not). Visibility is spec
22's tier-1 preload interposition, composed by
`build/resources/tebako_php_main.c` (the fs TU, which replaces
`sapi/cli/php_cli.o`'s `main` in the interpreter link) in two process
incarnations — tebako-runtime-python's exact model:

1. The **first** incarnation boots the driver in-process
   (`tebako_driver_boot`): mounts the env image from
   `TEBAKO_RUNTIME_IMAGE` and every `--tebako-image` payload triple,
   verifies the image's layout card (`lib/tebako/layout.yaml`), applies
   the jail, rewrites argv to the resolved entry, and arms the
   preload-shim injection env from the layout grant. A preload library
   binds only at exec, so —
2. when the boot mounted anything, `main` **re-execs itself** with the
   rewritten argv and the driver-armed env (`LD_PRELOAD` +
   `TEBAKO_PRELOAD_SHIM` + `TEBAKO_TFS_MOUNTS`, sentinel
   `TEBAKO_PHP_BOOTED`). The shim's constructor re-mounts the
   serialized mount table in the child; the child skips the boot and
   runs `php_cli_main`, whose libc IO the shim now serves from the VFS.

php needs no analog of `PYTHONHOME`: the interpreter's compiled-in
paths (the configure `--prefix`, the default `include_path`) spell the
baked mount root, and the shim serves the VFS at that path in the
child. `TEBAKO_MOUNT_ROOT`'s validated override is the driver's own
affair — the mounts move, never php's configuration.

Named exits are the driver's, surfaced unmodified: 65
(`TEBAKO_MOUNT_ROOT` malformed), 78 (ungranted override, or an env
image with no `preload_shim` grant — an unpatched php would boot
blind), 74 (re-exec failure), 69 (an unavailable payload image, named
on stderr).

## The extension set (v1 honest minimum)

The configure line is fixed (`PhpBuild::CONFIGURE_ARGS`):
`--disable-all --disable-cgi --disable-phpdbg --enable-cli
--enable-phar` — the honest minimal set: CLI SAPI only (no cgi, no
phpdbg), phar on (the ecosystem's own packaging form), every
extension **static in the exe** (nothing dlopened, nothing
host-provided). `--disable-all` flips every extension default off; the
always-on extensions (Core, date, hash, json, pcre, random, Reflection,
SPL, standard) are not options and ride regardless. The result links
against the libc family only — the audience rule (a user running tebako
packages installs nothing) holds by construction.

php-src is NTS (non-ZTS) — the upstream default; a ZTS flavor would be
a version-string flavor line when a payload census demands it (spec 28
§8's truffleruby precedent), never a new selector axis.

Extension breadth (openssl, mbstring, intl, …) and the composer lane
land together as their own increment: each added extension's library
closure must bind statically or ride the image, and composer needs
openssl + phar + a spawn-surface declaration — a design step, not a
flag flip.

## The artifacts (per version × triplet)

- `tebako-runtime-<tebako>-php-<php>-<triplet>[.exe]` — the
  interpreter: `php` cli with the spec-17 driver linked in (the fs TU
  as `main`).
- `tebako-runtime-<tebako>-php-<php>-<triplet>.tfs` — the env image:
  the php install tree with the build-time surface pruned (`bin/`
  wholesale — the build-tree php copy ships as the exe, `phar.phar`'s
  shebang names a host php, phpize/php-config are extension-build
  tooling — plus `include/`, `share/`, `lib/php/build/`), the preload
  shim at `lib/tebako/` (REQUIRED: the unpatched interpreter cannot
  read its own mounted image without it, so a missing shim is a hard
  build error, never the ruby factory's degrade), the layout card
  (`lib/tebako/layout.yaml`: era 2, `mount_root_override` granted,
  `preload_shim` path), and the L1 payload manifest
  (`__tpkg__/manifest.yaml`). Packed by `tfs mkimage` (the limnifs
  writer — the current default format; a build-time factory tool,
  never a runtime dependency of the shipped package).
- `<package>.abi` — the exe's abi facet: the Zend module API version a
  compiled extension pins (read from the built source's
  `Zend/zend_modules.h` `ZEND_MODULE_API_NO`); the release flow folds it
  into the manifest entry's additive `abi` key when publish lands.
- `<package>.contract.yaml` — the era-2 provenance card
  (`contract_era` / `mount_root` / `image_layout` / `built_from` + the
  additive `link_unit` block naming the consumed product unit).
- `<image>.sha256` — the checksum sidecar next to the env image, in the
  tebako store's trust-anchor shape (`"<sha256>  <filename>\n"`).

The exe ships **unstripped**: the symbol table is the
symbol-provenance gate's evidence on every platform, and runtime size
is not the gated artifact (the bootstrap is). The
`<package>.manifest.json` shard — the release manifest entry with the
sidecars folded in — is derived by the tebako-release gem at publish
time (spec 13 §2a's write-once per-leg metadata unit), never built
here; the factory emits exactly the sidecars it folds.

## The flow

```
www.php.net release tarball      tamatebako/tebako release
php-<v>.tar.gz (sha256-pinned    link-unit-<ver>-<pid>.tar.gz
in versions.yml)                 (spec-17 driver + tfs + closure)
        |                                   |
        v                                   v
   fetch + verify  ────────►  link the driver into the php cli
        configure && make (--prefix=<mount root>, NTS, static exts)
                        |
                        v
        assemble env layout (install tree pruned + preload shim
        + layout card + L1 manifest)
        pack <package>.tfs  (tfs mkimage — limnifs writer)
                        |
                        v
        provenance gate (ci/check_symbol_provenance.sh)
        boot smoke (tools/boot_smoke: bare/boot/payload boots,
        TEBAKO_MOUNT_ROOT 65/78 parity, bad-mount 69)
```

The source tarballs are php.net's own (no tamatebako php source factory
exists yet); the link unit is a **published product release artifact**.
Both are consumed by pin (`versions.yml` sha256 / `contract.yml`
`link_unit_release`) — never source checkouts of sibling repos
(prebuilt artifacts flow downward).

## Matrix grammar

The env vocabulary lives in `.github/matrix.json` (five rows: linux-gnu
x86_64, linux-musl x86_64 + arm64 in the digest-pinned tpkg-builder
containers, macos x86_64 + arm64 runner-native); the
version catalog lives in `contract.yml` (the SSOT) — versions, tags,
and SHAs never appear in workflow YAML. The dispatch filters are
`php_filter=full|tidy|catalog|<list>`, `platform=all|linux-gnu|…`,
`arch_filter=all|x86_64|arm64` — the python factory's grammar, so the
next platform's increment adds a matrix row, never a re-derivation.

## contract.yml — the pins

- `contract_version: 2` — the bootstrap ↔ runtime contract (spec 17
  grammar). Floored at 2 by the schema: no contract-1 era exists here.
  Bump rules mirror the other factories' (+1 in lockstep with the
  compiled-in `TEBAKO_CONTRACT_VERSION`, same commit — enforced by the
  driver-source parity arm of `scripts/check_contract.rb`).
- `container_version: "v1"` + `container_digests:` — the tpkg-builder
  tag line and its immutable ghcr manifest digests (born pinned — the
  ruby#381 idiom); the preflight job proves recorded == live before any
  leg spends compute.
- `link_unit_release: "v2.8.66"` — the tamatebako/tebako release whose
  prebuilt link unit the legs consume (the v2.8 driver line plus the
  raw-syscall interposition pair, tebako#935/#937).
- `macos_deployment_target: "14.0"` — the macOS support floor
  (tebako-runtime-python#81's pin, same value): stamped into the exe's
  LC_BUILD_VERSION minos via `MACOSX_DEPLOYMENT_TARGET`
  (`PhpBuild#floor_env`) and asserted at the provenance gate.
- `release_tooling: "v0.5.1"` — the tamatebako/tebako-release-tooling
  tag the Gemfile pins (the publish/sign/audit machinery's single
  owner; the factory's policy rides `scripts/release_adapter.rb`).
- `php:` — the version catalog (`catalog` / `full` / `tidy` sets).
  The per-version **source pins** (url + sha256) live in
  `versions.yml`; `scripts/check_contract.rb` cross-locks the two (a
  version in one but not the other is a config bug).

## Layout

- `VERSION` — the package version: package names and (eventually) the
  release tag follow it (`v$(cat VERSION)`). `0.1.0` is the opening
  line.
- `contract.yml` + `schema/` — the pins and the version catalog, and
  their JSON Schema; `scripts/check_contract.rb` validates (CI),
  including the driver-source parity arm (contract.yml ↔ the tebako
  driver's compiled-in contract version at the pinned link-unit
  release).
- `versions.yml` — the php.net source pins (url + sha256 per version).
- `scripts/versions` — emits the catalog / resolves the dispatch filter
  grammar / reads the pins (contract.yml is the SSOT).
- `scripts/compute_matrix.rb` — the matrix engine: catalog × env
  vocabulary under the dispatch filters → the leg matrix (with
  `host_id` and `link_unit_pid`), plus the `--format env|phps` forms
  the release job's expectations read.
- `scripts/release_adapter.rb` — this factory's tebako-release
  declaration (repo, language, the package-name grammar's version
  capture) through the gem's adapter seam.
- `tools/build_runtime` — the build entry point (fetch → verify →
  build → link → pack → package → sidecars).
- `tools/boot_smoke` — the post-build acceptance gate (8 scenarios:
  bare/boot/payload/compute-floor/bad-mount + the `TEBAKO_MOUNT_ROOT`
  override trio). Needs `TEBAKO_TFS` (the tfs CLI, for the fixture
  images) and the runtime-packages tree.
- `tools/registry_update.rb` — the registry render (spec 04 §2's
  mirror): the release's `.manifest.json` shards → `tpkg-registry.yaml`.
- `build/lib/tebako_php_builder/` — the build model (the
  tebako-runtime-python `build/lib` port): Contract, Platform,
  PhpVersion, SourceFetcher, LinkUnit, Mlibs, PhpBuild, ImageBuilder,
  ImageManifest, ImagePackager, TfsTool, Builder.
- `build/resources/tebako_php_main.c` — the fs TU template (the
  interpreter's real `main`; see the re-exec section).
- `ci/check_symbol_provenance.sh` — the symbol-provenance gate: the
  exe defines `tebako_driver_boot` / `tebako_mount_point` /
  `tebako_driver_contract_version` / `main` / `php_cli_main`, and
  `main` forwards to `tebako_driver_boot`; plus the dependency-closure
  audits (ELF NEEDED under the glibc/musl allowlist; Mach-O dylibs
  confined to `/usr/lib/` + `/System/Library/` with the minos floor).
- `ci/macos-sign-notarize-runtime.sh` + `ci/runtime.entitlements` —
  the spec 31 sign+notarize arm (Developer ID Application, hardened
  runtime; gated on `APPLE_SIGNING_ENABLED`, inert without it).
- `.github/workflows/_build-platform.yml` — the one per-platform
  workflow (parity → compute → preflight → build → publish → verify),
  called by the three thin triggers (`build-linux-gnu.yml`,
  `build-linux-musl.yml`, `build-macos.yml`) and by `publish.yml` (the
  release coordinator: per-leg publish+sign fan-out, the whole-matrix
  audit, the registry render + bot PR).
- `.github/workflows/lint.yml` — the static gate: schema validation,
  catalog/matrix resolution, the `ruby -c` sweep, YAML/JSON parse
  checks.

## Follow-ups

1. The first release (the pipeline is dispatch-proven; cutting
   `v0.1.0` is the owner's call, never the agent's).
2. The windows leg (needs the spec 17 §7 materialize tier branches in
   the fs TU).
3. Extension breadth + the composer lane (see the extension-set
   section).
4. The boot-contract parity suite (`spec/`) against the ruby driver's
   contract suite where the cases overlap.
5. The hello-runtimes acceptance arm.
6. The php.net release monitor.
