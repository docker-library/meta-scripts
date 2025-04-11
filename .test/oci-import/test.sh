#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"

set -x

cd "$dir"

export BASHBREW_META_SCRIPTS=../..

rm -rf temp
source out.sh

# make sure we don't commit the rootfs tarballs
find temp -type f -size '+1k' -print -delete
