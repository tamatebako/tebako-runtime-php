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

module TebakoPhpBuilder
  # Download, SHA256-verification and caching of the php-src release
  # tarballs published by php.net (php-<version>.tar.gz). There is no
  # tamatebako source factory for php yet (the census increment builds
  # from pristine upstream), so the trust anchor is THIS repo's
  # versions.yml: the sha256 recorded beside each url, pinned at the
  # commit that introduced the version — a checksum mismatch is a hard
  # error, never a refetch (tebako-runtime-python's SourceFetcher
  # discipline, with the release SHA256SUMS replaced by the in-repo pin).
  class SourceFetcher
    def initialize(cache_dir:, contract: TebakoPhpBuilder::Contract.new, mirror: nil)
      @contract = contract
      @mirror = mirror&.sub(%r{/+\z}, "")
      @cache_dir = cache_dir
    end

    def asset_name(php_version)
      "php-#{php_version}.tar.gz"
    end

    # Returns [tarball_path, sha256] for the requested php version.
    def fetch(php_version)
      pin = @contract.source_pin(php_version)
      expected = pin["sha256"].downcase
      name = asset_name(php_version)
      tarball = File.join(@cache_dir, "php-src", name)
      return [tarball, expected] if File.file?(tarball) && TebakoPhpBuilder::BuildHelpers.sha256_file(tarball) == expected

      FileUtils.rm_f(tarball)
      url = @mirror ? "#{@mirror}/#{name}" : pin["url"]
      TebakoPhpBuilder::BuildHelpers.download(url, tarball, code: 122)
      actual = TebakoPhpBuilder::BuildHelpers.sha256_file(tarball)
      return [tarball, expected] if actual == expected

      FileUtils.rm_f(tarball)
      raise TebakoPhpBuilder::Error.new(
        "#{name}: expected SHA256 #{expected} (versions.yml), got #{actual}; download deleted", 121
      )
    end
  end
end
