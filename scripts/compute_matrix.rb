#!/usr/bin/env ruby
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

# Compute the build-leg matrix for _build-platform.yml / publish.yml: the
# php set (resolved from contract.yml — the same read scripts/versions
# performs) x the env vocabulary (.github/matrix.json — tebako-runtime-
# python's grammar), sliced by the dispatch filters. Emits a GitHub
# Actions matrix JSON document on stdout. Stdlib only.
#
# Usage: compute_matrix.rb [--format matrix|env|phps]
#   matrix  (default) the GHA matrix document {"include": [leg, ...]} —
#           extra top-level keys are impossible (GHA would read them as
#           matrix variables), so the other two forms exist
#   env     the selected matrix.json rows as a JSON array (each + host_id)
#           — the release job's EXPECTED_ENV_MATRIX
#   phps    the selected php versions as a JSON array — the release job's
#           EXPECTED_PHP_MATRIX
#
# Filters (env vars, mirroring the other factories' dispatch grammar):
#   PHP_FILTER       full | tidy | catalog | comma-separated versions (default: full)
#   PLATFORM_FILTER  all | linux-gnu | linux-musl | macos | windows      (default: all)
#   ARCH_FILTER      all | x86_64 | arm64                                (default: all)
#
# Every leg carries:
#   php / os / arch / host    — the matrix coordinates
#   host_id                   — this factory's package-name platform id
#                               (Platform::HOST_IDS — the exe/image
#                               grammar tebako-runtime-<ver>-php-<php>-<host_id>)
#   container                 — the tpkg-builder image ref with
#                               contract.yml's container_version tag
#                               applied, null for the runner-native legs
#                               (macos — the documented tebako-ci-containers
#                               exception)
#   link_unit_pid             — the product release's platform id for the
#                               link-unit asset name (Platform::LINK_UNIT_PIDS)
#   sign_tool_host_id         — the in-leg sign step's tebako-pkg must
#                               EXECUTE on the leg's runner, and musl legs
#                               build inside the alpine container on a glibc
#                               ubuntu host: a musl-linked tool cannot exec
#                               there (its ELF interpreter is absent). The
#                               tool's platform is the runner's, never the
#                               artifact's.
#
# Named errors, exit 64: an unknown platform/arch filter, an unknown
# --format, or a matrix.json row outside the known vocabulary is a config
# bug, never a skipped leg.

require "json"
require "yaml"

REPO_ROOT = File.expand_path("..", __dir__).freeze
$LOAD_PATH.unshift(File.join(REPO_ROOT, "build", "lib"))

require "tebako_php_builder"

CONTRACT_YML = File.join(REPO_ROOT, "contract.yml").freeze
MATRIX_JSON = File.join(REPO_ROOT, ".github", "matrix.json").freeze

PLATFORMS = %w[linux-gnu linux-musl macos windows].freeze
ARCHES = %w[x86_64 arm64].freeze

def usage_error(message)
  warn "compute_matrix: #{message}"
  exit 64
end

format = "matrix"
if (idx = ARGV.index("--format"))
  format = ARGV[idx + 1].to_s
  usage_error "--format expects matrix | env | phps" unless %w[matrix env phps].include?(format)
elsif !ARGV.empty?
  usage_error "unknown argument(s): #{ARGV.join(', ')} (the only option is --format matrix|env|phps)"
end

contract = YAML.load_file(CONTRACT_YML)
php_sets = contract.fetch("php") { usage_error "#{CONTRACT_YML} carries no php: catalog" }
catalog = php_sets.fetch("catalog") { usage_error "#{CONTRACT_YML} php: carries no catalog key" }
container_version = contract.fetch("container_version") do
  usage_error "#{CONTRACT_YML} carries no container_version pin"
end

php_filter = ENV.fetch("PHP_FILTER", "full")
phps =
  case php_filter
  when "full", "tidy", "catalog"
    php_sets.fetch(php_filter) { usage_error "#{CONTRACT_YML} php: carries no #{php_filter} set" }
  when ""
    usage_error "PHP_FILTER is empty — expected full | tidy | catalog | a comma-separated version list"
  else
    versions = php_filter.split(",").map(&:strip).reject(&:empty?)
    unknown = versions - catalog
    usage_error "unknown php version(s) #{unknown.join(', ')} — catalog knows: #{catalog.join(', ')}" unless unknown.empty?
    versions
  end

platform_filter = ENV.fetch("PLATFORM_FILTER", "all")
unless platform_filter == "all" || PLATFORMS.include?(platform_filter)
  usage_error "unknown platform #{platform_filter.inspect} — expected all | #{PLATFORMS.join(' | ')}"
end

arch_filter = ENV.fetch("ARCH_FILTER", "all")
unless arch_filter == "all" || ARCHES.include?(arch_filter)
  usage_error "unknown arch #{arch_filter.inspect} — expected all | #{ARCHES.join(' | ')}"
end

env = JSON.parse(File.read(MATRIX_JSON)).fetch("env")

legs = []
selected_env = []
env.each do |row|
  os = row.fetch("os")
  arch = row.fetch("arch")
  host_id = TebakoPhpBuilder::Platform.host_id_for(os, arch)
  link_unit_pid = TebakoPhpBuilder::Platform.link_unit_pid_for(os, arch)
  next unless platform_filter == "all" || platform_filter == os
  next unless arch_filter == "all" || arch_filter == arch

  container = row["container"] && "#{row['container']}:#{container_version}"
  env_admitted = false
  phps.each do |php|
    # The line grammar is validated at the contract gate; the planner
    # re-validates so a catalog drift fails HERE (exit 64), never mid-leg.
    begin
      TebakoPhpBuilder::PhpVersion.new(php)
    rescue TebakoPhpBuilder::Error => e
      usage_error "catalog line #{php.inspect}: #{e.message}"
    end
    legs << {
      php: php,
      os: os,
      arch: arch,
      host: row.fetch("host"),
      host_id: host_id,
      container: container,
      link_unit_pid: link_unit_pid,
      sign_tool_host_id: (os == "linux-musl" ? "linux-gnu-#{arch}" : host_id)
    }
    # The env row joins the expectations only when the row EMITTED a leg:
    # the audit reads EXPECTED_ENV_MATRIX x EXPECTED_PHP_MATRIX, so a
    # gated row must not survive into env. matrix/env/phps all derive
    # from the same filtered walk.
    unless env_admitted
      selected_env << row.merge("host_id" => host_id)
      env_admitted = true
    end
  end
end

case format
when "matrix" then puts JSON.generate({ include: legs })
when "env" then puts JSON.generate(selected_env)
when "phps" then puts JSON.generate(phps.select { |php| legs.any? { |leg| leg[:php] == php } })
end
