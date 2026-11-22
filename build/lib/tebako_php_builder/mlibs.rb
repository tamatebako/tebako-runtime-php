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

module TebakoPhpBuilder
  # The tebako link line for the php cli exe link (the BUILD_CLI recipe's
  # appended $(TEBAKO_LIBS)): the scoped Rust staticlibs + the native
  # closure, ELF legs wrapped in -Wl,--start-group/--end-group (the
  # dwarfs/codec archives have circular member-level references).
  #
  # tebako-runtime-python's Mlibs port, reduced by php's extension policy
  # (README): the minimal static extension set binds NO openssl/zlib of
  # its own, so — unlike python — no platform static archives are
  # preferred over the closure's (python's covered_basenames drops the
  # closure's libssl/libcrypto/libz so its _ssl/zlib modules and the
  # closure share ONE copy; php has no second consumer, so the closure
  # rides COMPLETE). The static C++/gcc runtime tail and the libc-family
  # statics (rt/util, proven safe by the ruby factory) follow the group;
  # the rest of libc stays dynamic (always present on a glibc/musl host).
  #
  # darwin/msys link shapes arrive with their legs (the skeleton builds
  # linux-gnu only); a non-ELF platform is a named error here, never a
  # wrong link line.
  class Mlibs
    def initialize(platform:, link_unit:, link_unit_dir:)
      @platform = platform
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
    end

    # The $(TEBAKO_LIBS) value substituted into the generated Makefile.
    def tebako_libs
      unless @platform.linux?
        raise TebakoPhpBuilder::Error.new(
          "no tebako link line for #{@platform.ostype} yet — the skeleton ships the ELF (linux) " \
          "shape only; macos/msys arrive with their legs", 112
        )
      end

      elf_libs
    end

    private

    # ELF legs: the group around the tebako set (complete closure — the
    # class comment's no-second-consumer rule), then the static C++
    # runtime, then the libc-family tail statically where ruby proved it
    # safe (rt/util), the rest dynamically (always present on a
    # glibc/musl host).
    def elf_libs
      tail = %w[-static-libgcc -l:libstdc++.a -lgcc_eh]
      tail += @platform.musl? ? %w[-ldl -lpthread] : %w[-l:librt.a -l:libutil.a -ldl -lpthread]
      (["-Wl,--start-group"] + @link_unit.libraries(@link_unit_dir) + ["-Wl,--end-group"] + tail).join(" ")
    end
  end
end
