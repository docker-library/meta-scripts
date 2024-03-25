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

rm -rf "$dir/coverage"
mkdir -p "$dir/coverage"
export GOCOVERDIR="${GOCOVERDIR:-"$dir/coverage"}"

rm -f "$dir/../bin/builds" # make sure we build with -cover for sure
time "$dir/../builds.sh" --cache "$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"

# test again, but with "--cache=..." instead of "--cache ..." (which also lets us delete the cache and get slightly better coverage reports at the expense of speed / Hub requests)
time "$dir/../builds.sh" --cache="$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"

# test "lookup" code for more edge cases
"$dir/../.go-env.sh" go build -cover -trimpath -o "$dir/../bin/lookup" ./cmd/lookup
lookup=(
	# force a config blob lookup for platform object creation (and top-level Docker media type!)
	'tianon/test@sha256:2f19ce27632e6baf4ebb1b582960d68948e52902c8cfac10133da0058f1dab23'
	# (this is the first Windows manifest of "tianon/test:index-no-platform-smaller" referenced below)

	# tianon/test:index-no-platform-smaller - a "broken" index with *zero* platform objects in it (so every manifest requires a platform lookup)
	'tianon/test@sha256:347290ddd775c1b85a3e381b09edde95242478eb65153e9b17225356f4c072ac'
	# (doing these in the same run means the manifest from above should be cached and exercise more codepaths for better coverage)

	--type manifest 'tianon/test@sha256:347290ddd775c1b85a3e381b09edde95242478eb65153e9b17225356f4c072ac' # same manifest again, but without SynthesizeIndex
	--type blob 'tianon/test@sha256:d2c94e258dcb3c5ac2798d32e1249e42ef01cba4841c2234249495f87264ac5a' # first config blob from the above
	# and again, but this time HEADs
	--head --type manifest 'tianon/test@sha256:347290ddd775c1b85a3e381b09edde95242478eb65153e9b17225356f4c072ac'
	--head --type blob 'tianon/test@sha256:d2c94e258dcb3c5ac2798d32e1249e42ef01cba4841c2234249495f87264ac5a'

	# again with things that aren't cached yet (tianon/true:oci, specifically)
	--head --type blob 'tianon/true@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e' # config blob
	--head --type manifest 'tianon/true:oci@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d'
	--type blob 'tianon/true@sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e' # config blob
	--type manifest 'tianon/true:oci@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d'
	'tianon/true:oci@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d'

	# tag lookup! (but with a hopefully stable example tag -- a build of notary:server)
	--head 'oisupport/staging-amd64:71756dd75e41c4bc5144b64d36b4834a5a960c495470915eb69f96e9f2cb6694'
	--head 'oisupport/staging-amd64:71756dd75e41c4bc5144b64d36b4834a5a960c495470915eb69f96e9f2cb6694' # twice, to exercise "tag is cached" case
	--type manifest 'oisupport/staging-amd64:71756dd75e41c4bc5144b64d36b4834a5a960c495470915eb69f96e9f2cb6694'
	'oisupport/staging-amd64:71756dd75e41c4bc5144b64d36b4834a5a960c495470915eb69f96e9f2cb6694'

	# exercise 404 codepaths
	"tianon/this-is-a-repository-that-will-never-ever-exist-$RANDOM-$RANDOM:$RANDOM-$RANDOM"
	--head "tianon/this-is-a-repository-that-will-never-ever-exist-$RANDOM-$RANDOM:$RANDOM-$RANDOM"
	'tianon/test@sha256:0000000000000000000000000000000000000000000000000000000000000000'
)
"$dir/../bin/lookup" "${lookup[@]}" | jq -s > "$dir/lookup-test.json"

# don't leave around the "-cover" versions of these binaries
rm -f "$dir/../bin/builds" "$dir/../bin/lookup"

# Go tests
"$dir/../.go-env.sh" go test -cover ./... -args -test.gocoverdir="$GOCOVERDIR"

# combine the coverage data into the "legacy" coverage format (understood by "go tool cover") and pre-generate HTML for easier digestion of the data
"$dir/../.go-env.sh" go tool covdata textfmt -i "$GOCOVERDIR" -o "$dir/coverage.txt"
"$dir/../.go-env.sh" go tool cover -html "$dir/coverage.txt" -o "$dir/coverage.html"
"$dir/../.go-env.sh" go tool cover -func "$dir/coverage.txt"

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
