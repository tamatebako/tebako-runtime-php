# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "fileutils"
require "open3"

module TebakoPhpBuilder
  # The relocatable php-cli build (tools/build_runtime phases 3-4): the
  # pristine php.net tarball is extracted, configured, and built IN TREE
  # (the extracted copy is this factory's scratch — never a published
  # input), and the spec-17 driver is linked into the php exe by
  # build-time substitutions on the GENERATED Makefile (the python
  # factory's Makefile.pre substitution analog — a generated-build-file
  # edit, never a source patch; the php.net tarball ships pristine):
  #
  #   * the sapi/cli/php_cli.lo compile recipe gains -Dmain=php_cli_main,
  #     renaming the interpreter's entry point at compile time ("main"
  #     occurs in php_cli.c exactly once as the function definition; the
  #     remaining occurrences are a string literal and an include
  #     filename, where a macro never expands);
  #   * BUILD_CLI's link recipe appends sapi/cli/tebako_php_main.o (the
  #     fs TU — build/resources/tebako_php_main.c — providing the real
  #     main, which boots the driver and forwards to php_cli_main) and
  #     $(TEBAKO_LIBS) (the scoped driver + tfs + closure, Mlibs);
  #   * the $(SAPI_CLI_PATH) rule gains the fs TU object as a
  #     prerequisite, and the factory appends the fs TU's compile rule +
  #     the TEBAKO_LIBS variable under a marker comment.
  #
  # php's generated Makefile is the durable substitution target: nothing
  # regenerates it short of re-running configure (there is no
  # Makefile.pre two-step), and a re-run of configure regenerates it
  # without the marker, so the pass re-applies. The substitution also
  # removes the stale php_cli objects it invalidates — an already-built
  # tree's php_cli.o would otherwise carry the unrenamed main into the
  # link (duplicate symbol), and make does not track recipe changes.
  class PhpBuild
    MARKER = "# --- tebako: the fs TU + driver link (factory substitution) ---"

    # The configure line — README's extension policy: the honest minimal
    # set (core + standard + the always-on spl/pcre/hash/json/date/
    # random/reflection + phar), CLI only, no cgi/phpdbg, everything
    # static in the exe. --disable-all flips every extension default off;
    # the always-on extensions are not options and ride regardless.
    CONFIGURE_ARGS = %w[
      --disable-all
      --disable-cgi
      --disable-phpdbg
      --enable-cli
      --enable-phar
    ].freeze

    def initialize(platform:, php_version:, prefix:, tarball:, src_sha256:, # rubocop:disable Metrics/ParameterLists,Metrics/MethodLength
                   link_unit:, link_unit_dir:, repo_root:, jobs: nil, macos_deployment_target: nil)
      @platform = platform
      @php_version = php_version
      @php = TebakoPhpBuilder::PhpVersion.new(php_version)
      @prefix = prefix
      @tarball = tarball
      @src_sha256 = src_sha256
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
      @repo_root = repo_root
      @jobs = jobs
      @macos_deployment_target = macos_deployment_target
    end

    attr_reader :src_dir, :stage_dir

    def run
      extract
      configure
      substitute_makefile
      write_fs_tu
      make
      install
      self
    end

    # The built interpreter exe in the build tree (the driver-linked one):
    # the cli SAPI's product (sapi/cli/php — SAPI_CLI_PATH, EXEEXT-empty
    # on POSIX).
    def exe_path
      File.join(src_dir, "sapi", "cli", "php#{@platform.exe_suffix}")
    end

    # The runtime's abi facet (the release shard's additive `abi` key):
    # the PHP API version a compiled extension pins (the Zend module API —
    # e.g. 20240924 for the 8.4 line), read from the built source's
    # Zend/zend_modules.h (ZEND_MODULE_API_NO — the value's single upstream
    # owner; main/php_version.h carries only the marketing version, and
    # reading the header beats parsing `php -i`, which no leg needs to
    # boot for).
    def abi
      @abi ||= begin
        header = File.join(src_dir, "Zend", "zend_modules.h")
        match = File.read(header).match(/^#define ZEND_MODULE_API_NO (\d+)$/)
        unless match
          raise TebakoPhpBuilder::Error.new(
            "no ZEND_MODULE_API_NO in #{header} — the upstream version header grammar drifted", 106
          )
        end
        match[1]
      end
    end

    # The compile flags the build ACTUALLY runs with, read back from the
    # generated Makefile's CFLAGS_CLEAN (the recipe's own record — the
    # contract card's built_from.cflags; available post-configure). The
    # read-back doubles as the build-side gate against the env-clobber
    # class (configure_env's comment): a Makefile whose compile flags
    # carry no -O option fails the build here, never at the boot smoke.
    # Public: Builder folds it into the package's .contract.yaml card.
    def recorded_cflags
      line = File.read(File.join(src_dir, "Makefile"))[/^CFLAGS_CLEAN = (.*)$/, 1]
      unless line
        raise TebakoPhpBuilder::Error.new(
          "no CFLAGS_CLEAN line in the generated Makefile — this php's build grammar drifted", 103
        )
      end
      if (line.split & %w[-O0 -O1 -Og -Od]).any? || line.split.grep(/\A-O[23]\z/).empty?
        raise TebakoPhpBuilder::Error.new(
          "the generated Makefile compiles php with no -O2/-O3 (CFLAGS_CLEAN=#{line.inspect}) — " \
          "a slow build ships green under a boot-only gate (the env-clobber class, " \
          "tebako-runtime-python#79); configure_env pins the flags", 103
        )
      end
      line
    end

    private

    def mlibs
      @mlibs ||= TebakoPhpBuilder::Mlibs.new(platform: @platform, link_unit: @link_unit,
                                             link_unit_dir: @link_unit_dir)
    end

    def ncores
      @jobs || @platform.ncores
    end

    def src_parent
      File.join(@prefix, "src")
    end

    def tree_name
      "php-#{@php.base_version}-src"
    end

    def extract
      @src_dir = File.join(src_parent, tree_name)
      marker = File.join(src_parent, ".#{tree_name}.src-sha256")
      if File.directory?(@src_dir) && File.file?(marker) && File.read(marker).strip == @src_sha256
        puts "-- php source #{@php_version} already extracted (sha256 #{@src_sha256})"
        return
      end

      FileUtils.rm_rf(@src_dir, secure: true)
      FileUtils.mkdir_p(src_parent)
      # A crashed extract's staging leftover is reclaimed FIRST — tar
      # onto a non-empty dir would keep files the tarball no longer
      # carries (debris, not a pristine tree).
      FileUtils.rm_rf(staging_parent, secure: true)
      TebakoPhpBuilder::BuildHelpers.run_with_capture(
        ["tar", "-xzf", @tarball, "-C", staging_parent]
      )
      staged = File.join(staging_parent, "php-#{@php.base_version}")
      unless File.directory?(staged)
        raise TebakoPhpBuilder::Error.new(
          "#{@tarball} did not extract to php-#{@php.base_version} under #{staging_parent}", 103
        )
      end
      FileUtils.mv(staged, @src_dir)
      FileUtils.rm_rf(staging_parent, secure: true)
      File.write(marker, "#{@src_sha256}\n")
    end

    # The extraction staging dir (sibling of the build trees; extract
    # reclaims it before every unpack and removes it after the rename).
    def staging_parent
      dir = File.join(src_parent, ".extract-staging")
      FileUtils.mkdir_p(dir)
      dir
    end

    # The relocatable configure: the compiled-in prefix IS the mount root
    # (the default include_path and the php.ini search path then spell
    # the runtime VFS path). The extension policy is CONFIGURE_ARGS (the
    # class comment); NTS (non-ZTS) is the default and stays.
    def configure
      if @platform.msys?
        raise TebakoPhpBuilder::Error.new(
          "the windows legs arrive with the spec 17 §7 materialize tier — " \
          "this factory builds POSIX legs only today", 103
        )
      end

      args = ["./configure", "--prefix=#{@platform.mount_root}"] + CONFIGURE_ARGS
      puts "-- Configuring php #{@php_version} (#{@platform.host_id})"
      TebakoPhpBuilder::BuildHelpers.run_with_capture(args, env: configure_env, chdir: src_dir)
      puts "   ... compile flags (CFLAGS_CLEAN): #{recorded_cflags}"
    rescue TebakoPhpBuilder::Error => e
      raise e if e.error_code == 103 && e.message.include?("POSIX")

      raise TebakoPhpBuilder::Error.new("'build_runtime' configure step failed: #{e.message}", 103)
    end

    # linux-gnu: the python factory's lesson, one layer deeper for php —
    # the tpkg-builder gnu images export CFLAGS=-pthread, and under
    # autoconf an env-set CFLAGS REPLACES configure's -g -O2 default
    # outright (CPython is immune: its OPT carries the -O3 separately;
    # php's CFLAGS_CLEAN derives from the env value alone). So an
    # unpinned php build on the gnu container compiles UNOPTIMIZED — the
    # tebako-runtime-python#79 slow-build class, green under every
    # boot-only gate. CFLAGS=-O2 -pthread keeps the image's thread flag
    # and restores the optimization the default would have had (the
    # boot smoke's compute-floor tripwire pins the outcome). The
    # link-side -pthread: the link recipe never sees CFLAGS, and the
    # closure's Rust objects reference pthread_create/sem_init, which
    # glibc < 2.34 keeps in libpthread.
    # linux-musl: the musl image exports no CFLAGS (verified against the
    # digest-pinned container), so configure's own -g -O2 default applies
    # and musl carries pthread in libc — nothing to pin.
    def configure_env
      env = if @platform.linux_gnu?
              { "CFLAGS" => "-O2 -pthread", "LDFLAGS" => "-pthread" }
            else
              {}
            end
      env.merge(floor_env)
    end

    # The macOS support floor rides the WHOLE build as
    # MACOSX_DEPLOYMENT_TARGET — configure's probes compile+link, and the
    # exe's final link (inside make) is what clang stamps as
    # LC_BUILD_VERSION minos. Unpinned, the stamp floats with the build
    # host's OS (tebako-runtime-python#81: the Intel runtime refused to
    # load on macOS 14). The pin is contract.yml's
    # macos_deployment_target, a product decision, and the provenance
    # gate asserts the recorded minos equals it. Off-macOS the env is
    # empty and merges as a no-op.
    def floor_env
      return {} unless @platform.macos?

      floor = @macos_deployment_target.to_s
      if floor.empty?
        raise TebakoPhpBuilder::Error.new(
          "no macos_deployment_target pin (contract.yml) — the macOS support floor is a product decision, " \
          "never the runner image's accident (tebako-runtime-python#81)", 64
        )
      end
      { "MACOSX_DEPLOYMENT_TARGET" => floor }
    end

    # The build-time substitutions on the generated Makefile. Every
    # anchor must match exactly once — a php whose build grammar drifted
    # is a named error, never a half-applied edit.
    def substitute_makefile
      makefile = File.join(src_dir, "Makefile")
      content = File.read(makefile)
      if content.include?(MARKER)
        puts "   ... Makefile substitutions already applied"
        return
      end

      substitutions = [
        # 1. Rename the interpreter's entry point at compile time (the
        #    class comment). The recipe line is the ONLY one naming
        #    php_cli.c -> php_cli.lo.
        [%r{^(\t\$\(LIBTOOL\) --tag=CC --mode=compile .*)( -c \S*sapi/cli/php_cli\.c -o sapi/cli/php_cli\.lo.*)$},
         "\\1 -Dmain=php_cli_main\\2"],
        # 2. The link recipe gains the fs TU object + the tebako link line.
        [/^(BUILD_CLI = .*\$\(ZEND_EXTRA_LIBS\))( -o \$\(SAPI_CLI_PATH\).*)$/,
         "\\1 sapi/cli/tebako_php_main.o $(TEBAKO_LIBS)\\2"],
        # 3. The fs TU object joins the CLI target's prerequisites.
        [%r{^(\$\(SAPI_CLI_PATH\): \$\(PHP_GLOBAL_OBJS\) \$\(PHP_BINARY_OBJS\) \$\(PHP_CLI_OBJS\))(.*)$},
         "\\1 sapi/cli/tebako_php_main.o\\2"]
      ]
      substitutions.each { |(pattern, replacement)| content = content.gsub(pattern, replacement) }
      content += "\n#{MARKER}\nTEBAKO_LIBS = #{mlibs.tebako_libs}\n" \
                 "sapi/cli/tebako_php_main.o: sapi/cli/tebako_php_main.c\n" \
                 "\t$(CC) $(CPPFLAGS) -O2 -pthread -c sapi/cli/tebako_php_main.c -o sapi/cli/tebako_php_main.o\n"
      File.write(makefile, content)

      verify_substitutions(content)

      # The substitution invalidates any already-built php_cli object
      # (the class comment): force its recompilation under the renamed
      # main. A fresh tree carries none of these.
      FileUtils.rm_f(Dir.glob(File.join(src_dir, "sapi", "cli", "{php_cli.lo,php_cli.o,php_cli.dep}")) +
                     Dir.glob(File.join(src_dir, "sapi", "cli", ".libs", "php_cli.o")))
      puts "   ... Makefile substitutions applied"
    end

    def verify_substitutions(content)
      missing = []
      missing << "the php_cli.lo compile recipe (-Dmain=php_cli_main)" unless content.include?("-Dmain=php_cli_main -c ")
      missing << "the BUILD_CLI link recipe" unless content.match?(/^BUILD_CLI = .*sapi\/cli\/tebako_php_main\.o \$\(TEBAKO_LIBS\) -o \$\(SAPI_CLI_PATH\)/)
      missing << "the $(SAPI_CLI_PATH) prerequisites" unless content.match?(/^\$\(SAPI_CLI_PATH\): .*sapi\/cli\/tebako_php_main\.o/)
      return if missing.empty?

      raise TebakoPhpBuilder::Error.new(
        "Makefile substitution incomplete (#{missing.join(", ")}) — this php's generated-Makefile " \
        "grammar drifted from the factory's anchors", 103
      )
    end

    # The generated fs TU: the exe's real main() — boots the driver with
    # the baked mount root, exports the contract version, and re-execs
    # under the preload-shim injection when the image is mounted
    # (README's LINKED-driver section).
    def write_fs_tu
      template = File.read(File.join(@repo_root, "build", "resources", "tebako_php_main.c"))
      rendered = template.gsub("@MOUNT_ROOT@", @platform.mount_root)
      File.write(File.join(src_dir, "sapi", "cli", "tebako_php_main.c"), rendered)
      puts "   ... fs TU: sapi/cli/tebako_php_main.c (mount root #{@platform.mount_root})"
    end

    def make
      TebakoPhpBuilder::BuildHelpers.run_with_capture(["make", "-j", ncores.to_s], chdir: src_dir)
    rescue TebakoPhpBuilder::Error => e
      raise TebakoPhpBuilder::Error.new("'build_runtime' build step failed: #{e.message}", 104)
    end

    # Staged install: `make install INSTALL_ROOT=<stage>` lands the prefix
    # tree at <stage>/<mount root spelling> (php's Makefile spells every
    # destination $(INSTALL_ROOT)$(dir) with no separator, which composes
    # only because a POSIX prefix starts with a slash).
    def install
      @stage_dir = File.join(@prefix, "stage")
      FileUtils.rm_rf(@stage_dir, secure: true)
      FileUtils.mkdir_p(@stage_dir)
      TebakoPhpBuilder::BuildHelpers.run_with_capture(["make", "install", "INSTALL_ROOT=#{stage_dir}"], chdir: src_dir)
    rescue TebakoPhpBuilder::Error => e
      raise TebakoPhpBuilder::Error.new("'build_runtime' install step failed: #{e.message}", 105)
    end

    public

    # The staged prefix tree (the image root's content): stage/<root>
    # with the root spelling normalized ("/__tfs__" -> "__tfs__").
    def staged_prefix_tree
      spelling = @platform.mount_root.sub(%r{\A/+}, "")
      File.join(stage_dir, spelling).tap do |tree|
        next if File.directory?(tree)

        raise TebakoPhpBuilder::Error.new(
          "the staged install carries no #{spelling} tree under #{stage_dir} " \
          "(prefix #{@platform.mount_root} did not install as expected)", 105
        )
      end
    end
  end
end
