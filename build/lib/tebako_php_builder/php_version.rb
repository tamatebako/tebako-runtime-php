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
  # php version model (tebako-runtime-python's PythonVersion analog —
  # the version predicates and the derived name grammar). php lines are
  # plain x.y.z: no flavor axis exists yet (no jit/nts/zts line split;
  # the builds are NTS — README's extension-policy section). The source
  # tarball carries its integrity pin in versions.yml (this factory IS
  # the pin owner — no tamatebako source factory exists for php yet).
  class PhpVersion
    # The one owner of the line grammar (spec 00 §10): the schema's
    # catalog pattern mirrors it (asserted by the lint gate passing on
    # the same strings) — nothing re-derives it.
    LINE_PATTERN = /\A(?<base>\d+\.\d+\.\d+)\z/.freeze

    def initialize(php_version)
      @php_version = php_version
      parse_line
    end

    attr_reader :php_version, :base_version

    # The version's major.minor line as integers (8.4 for every 8.4.x),
    # so 9.x lines fall out naturally.
    def major_minor
      @major_minor ||= base_version.split(".").first(2).map(&:to_i)
    end

    # The abi_line the image manifest's provides block declares (spec 03
    # §2.2 — what native-extension payloads match their version constraint
    # against): the "8.4"-style line. (The exact PHP API version — the
    # Zend module API a compiled extension pins — rides the package's
    # .abi facet, read from the built source's main/php_version.h.)
    def abi_line
      major_minor.join(".")
    end

    # The interpreter API version the layout card declares (the schema's
    # required interpreter_api_version): php's "8.4"-style line. The
    # era-2 driver parses but does not gate on it.
    def api_version
      abi_line
    end

    private

    # Parse the line, enforcing the grammar. Named errors, exit 109 — a
    # malformed line is a config bug, never a silently misparsed name.
    def parse_line
      match = LINE_PATTERN.match(@php_version)
      unless match
        raise TebakoPhpBuilder::Error.new(
          "Invalid php version format '#{@php_version}'. Expected format: x.y.z", 109
        )
      end
      @base_version = match[:base]
    end
  end
end
