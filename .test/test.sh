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

time bashbrew fetch "$@"

time "$dir/../sources.sh" "$@" > "$dir/sources.json"

time "$dir/../builds.sh" --cache "$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"

# generate an "example commands" file so that changes to generated commands are easier to review
jq -r -L "$dir/.." '
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
		| "# \(first($b.source.allTags[])) [\($b.build.arch)]\n" + join("\n")
	)
	| join("\n\n")
' "$dir/builds.json" > "$dir/example-commands.sh"
