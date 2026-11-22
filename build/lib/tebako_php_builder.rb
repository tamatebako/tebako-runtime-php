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

# Tebako php runtime builder (tebako-runtime-php)
#
# Build tooling that produces tebako php runtime packages from the
# PRISTINE php-src release tarballs published by php.net
# (php-<version>.tar.gz, verified against the sha256 pins in
# versions.yml — there is no tamatebako source factory for php yet), with
# the spec-17 driver LINKED into the php cli executable (the ruby/python
# pattern, not the spec-29 wrapper). The interpreter is UNPATCHED, so the
# generated fs TU (build/resources/tebako_php_main.c) boots the driver
# in-process and re-execs the interpreter under the driver-armed
# preload-shim injection (the shim constructor re-mounts the serialized
# mount table in the child — spec 22's tier-1 visibility). This is the
# tebako-runtime-python build/lib port, php edition.
module TebakoPhpBuilder
  # Autoloads use absolute paths so the library loads regardless of the
  # caller's $LOAD_PATH.
  autoload :BuildHelpers,   File.expand_path("tebako_php_builder/build_helpers", __dir__)
  autoload :Builder,        File.expand_path("tebako_php_builder/builder", __dir__)
  autoload :Contract,       File.expand_path("tebako_php_builder/contract", __dir__)
  autoload :Error,          File.expand_path("tebako_php_builder/error", __dir__)
  autoload :ImageBuilder,   File.expand_path("tebako_php_builder/image_builder", __dir__)
  autoload :ImageManifest,  File.expand_path("tebako_php_builder/image_manifest", __dir__)
  autoload :ImagePackager,  File.expand_path("tebako_php_builder/image_packager", __dir__)
  autoload :LinkUnit,       File.expand_path("tebako_php_builder/link_unit", __dir__)
  autoload :Mlibs,          File.expand_path("tebako_php_builder/mlibs", __dir__)
  autoload :PhpBuild,       File.expand_path("tebako_php_builder/php_build", __dir__)
  autoload :PhpVersion,     File.expand_path("tebako_php_builder/php_version", __dir__)
  autoload :Platform,       File.expand_path("tebako_php_builder/platform", __dir__)
  autoload :SourceFetcher,  File.expand_path("tebako_php_builder/source_fetcher", __dir__)
  autoload :TfsTool,        File.expand_path("tebako_php_builder/tfs_tool", __dir__)
end
