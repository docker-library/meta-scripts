#!/usr/bin/env bash
set -Eeuo pipefail

export BASHBREW_ARCH_NAMESPACES='
	amd64 = amd64,
	arm32v5 = arm32v5,
	arm32v6 = arm32v6,
	arm32v7 = arm32v7,
	arm64v8 = arm64v8,
	i386 = i386,
	mips64le = mips64le,
	ppc64le = ppc64le,
	riscv64 = riscv64,
	s390x = s390x,
	windows-amd64 = winamd64,
'
export BASHBREW_STAGING_TEMPLATE='oisupport/staging-ARCH:BUILD'

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"
export BASHBREW_LIBRARY="$dir/library"

set -- docker:cli docker:dind docker:windowsservercore notary busybox:latest # a little bit of Windows, a little bit of Linux, a little bit of multi-stage, a little bit of oci-import
# (see "library/" and ".external-pins/" for where these come from / are hard-coded for consistent testing purposes)
# NOTE: we are explicitly *not* pinning "golang:1.19-alpine3.16" so that this also tests unpinned parent behavior (that image is deprecated so should stay unchanging)

time bashbrew fetch "$@"

time "$dir/../sources.sh" "$@" > "$dir/sources.json"

time "$dir/../builds.sh" --cache "$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"

# generate an "example commands" file so that changes to generated commands are easier to review
SOURCE_DATE_EPOCH=0 jq -r -L "$dir/.." '
	include "meta";
	[
		first(.[] | select(normalized_builder == "buildkit")),
		first(.[] | select(normalized_builder == "classic")),
		first(.[] | select(normalized_builder == "oci-import")),
		empty
	]
	| map(
		. as $b
		| commands
		| to_entries
		| map("# <\(.key)>\n\(.value)\n# </\(.key)>")
		| "# \($b.source.tags[0]) [\($b.build.arch)]\n" + join("\n")
	)
	| join("\n\n")
' "$dir/builds.json" > "$dir/example-commands.sh"
