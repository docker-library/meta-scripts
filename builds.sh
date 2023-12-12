#!/usr/bin/env bash
set -Eeuo pipefail

# TODO drop this from the defaults and set it explicitly in DOI instead (to prevent accidents)
: "${BASHBREW_STAGING_TEMPLATE:=oisupport/staging-ARCH:BUILD}"
export BASHBREW_STAGING_TEMPLATE

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"
if [ "$dir/builds.go" -nt "$dir/builds" ] || [ "$dir/om/om.go" -nt "$dir/builds" ] || [ "$dir/.go-env.sh" -nt "$dir/builds" ]; then
	{
		echo "building '$dir/builds' from 'builds.go'"
		"$dir/.go-env.sh" go build -v -o builds builds.go
		ls -l "$dir/builds"
	} >&2
fi
[ -x "$dir/builds" ]

"$dir/builds" "$@" | jq .
