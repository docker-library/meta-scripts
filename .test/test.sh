#!/usr/bin/env bash
set -Eeuo pipefail

export BASHBREW_ARCH_NAMESPACES=
export BASHBREW_STAGING_TEMPLATE='oisupport/staging-ARCH:BUILD'

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"
export BASHBREW_LIBRARY="$dir/library"

set -- docker:cli docker:dind docker:windowsservercore notary # a little bit of Windows, a little bit of Linux, a little bit of multi-stage
# (see "library/" and ".external-pins/" for where these come from / are hard-coded for consistent testing purposes)
# NOTE: we are explicitly *not* pinning "golang:1.19-alpine3.16" so that this also tests unpinned parent behavior (that image is deprecated so should stay unchanging)

time "$dir/../sources.sh" "$@" > "$dir/sources.json"
time "$dir/../builds.sh" "$dir/sources.json" > "$dir/builds.json"
