#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"

set -x

cd "$dir"

export BASHBREW_META_SCRIPTS=../..

rm -rf temp
source out.sh

# TODO this should be part of "oci-import.sh"
"$BASHBREW_META_SCRIPTS/helpers/oci-validate.sh" temp

# make sure we don't commit the rootfs tarballs
find temp -type f -size '+1k' -print -delete
# TODO rely on .gitignore instead so that when the test finishes, we have a valid + complete OCI layout locally (that we can test push code against, for example)?
