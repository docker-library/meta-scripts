#!/usr/bin/env bash
set -Eeuo pipefail

# TODO drop this from the defaults and set it explicitly in DOI instead (to prevent accidents)
: "${BASHBREW_STAGING_TEMPLATE:=oisupport/staging-ARCH:BUILD}"
export BASHBREW_STAGING_TEMPLATE

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"
bin="$dir/bin/builds"
if ( cd "$dir" && ./.any-go-nt.sh "$bin" ); then
	{
		echo "building '$bin'"
		"$dir/.go-env.sh" go build ${GOCOVERDIR:+-cover} -v -trimpath -o "$bin" ./cmd/builds
		ls -l "$bin"
	} >&2
fi
[ -x "$bin" ]

"$bin" "$@" | jq .
