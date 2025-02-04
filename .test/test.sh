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

doDeploy=
if [ "${1:-}" = '--deploy' ]; then
	doDeploy=1
fi

set -- docker:cli docker:dind docker:windowsservercore notary busybox:{latest,glibc,musl,uclibc} # a little bit of Windows, a little bit of Linux, a little bit of multi-stage, a little bit of oci-import (and a little bit of cursed busybox)
# (see "library/" and ".external-pins/" for where these come from / are hard-coded for consistent testing purposes)
# NOTE: we are explicitly *not* pinning "golang:1.19-alpine3.16" so that this also tests unpinned parent behavior (that image is deprecated so should stay unchanging)

time bashbrew fetch "$@"

time "$dir/../sources.sh" "$@" > "$dir/sources-doi.json"

# also fetch/include Tianon's more cursed "infosiftr/moby" example (a valid manifest with arch-specific non-archTags that end up mapping to the same sourceId)
bashbrew fetch infosiftr-moby
( BASHBREW_ARCH_NAMESPACES= "$dir/../sources.sh" infosiftr-moby > "$dir/sources-moby.json" )
# technically, this *also* needs BASHBREW_STAGING_TEMPLATE='tianon/zz-staging:ARCH-BUILD', but that's a "builds.sh" flag and separating that would complicate including this even more, so Tianon has run the following one-liner to "inject" those builds as if they lived in 'oisupport/staging-ARCH:BUILD' instead:
#   jq -r '[ .[] | select(any(.source.arches[].tags[]; startswith("infosiftr-moby:"))) | "tianon/zz-staging:\(.build.arch)-\(.buildId)" as $tianon | @sh "../bin/lookup \($tianon) | jq --arg img \(.build.img) \("{ indexes: { ($img): . } }")" ] | "{ " + join(" && ") + @sh " && cat cache-builds.json; } | jq -s --tab \("reduce .[] as $i ({ indexes: { } }; .indexes += $i.indexes)") > cache-builds.json.new && mv cache-builds.json.new cache-builds.json"' builds.json | bash -Eeuo pipefail -x
# (and then re-run the tests to canonicalize the file ordering)
jq -s 'add' "$dir/sources-doi.json" "$dir/sources-moby.json" > "$dir/sources.json"
rm -f "$dir/sources-doi.json" "$dir/sources-moby.json"

# an attempt to highlight tag mapping bugs in the future
jq '
	to_entries
	| map(
		# emulate builds.json (poorly)
		(.value.arches | keys[]) as $arch
		| .key += "-" + $arch
		| .value.arches = { ($arch): .value.arches[$arch] }

		# filter to just the list of canonical tags per "build"
		| .value |= [ .arches[$arch] | .tags[], .archTags[] ]
	)
	# combine our new pseudo-buildIds into overlapping lists of tags (see also "deploy.jq" and "tagged_manifests" which this is emulating)
	| reduce .[] as $i ({};
		.[ $i.value[] ] += [ $i.key ]
	)
' "$dir/sources.json" > "$dir/all-tags.json"

coverage="$dir/.coverage"
rm -rf "$coverage/GOCOVERDIR" "$coverage/bin"
mkdir -p "$coverage/GOCOVERDIR" "$coverage/bin"
export GOCOVERDIR="${GOCOVERDIR:-"$coverage/GOCOVERDIR"}"

time "$coverage/builds.sh" --cache "$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"
[ -s "$coverage/bin/builds" ] # just to make sure it actually did build/use an appropriate binary 🙈

# test again, but with "--cache=..." instead of "--cache ..." (which also lets us delete the cache and get slightly better coverage reports at the expense of speed / Hub requests)
time "$coverage/builds.sh" --cache="$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"

# test "lookup" code for more edge cases
"$dir/../.go-env.sh" go build -coverpkg=./... -trimpath -o "$coverage/bin/lookup" ./cmd/lookup
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
"$coverage/bin/lookup" "${lookup[@]}" | jq -s '
	[
		reduce (
			$ARGS.positional[]
			| if startswith("tianon/this-is-a-repository-that-will-never-ever-exist-") then
				gsub("[0-9]+"; "$RANDOM")
			else . end
		) as $a ([];
			if .[-1][-1] == "--type" then
				.[-1][-1] += " " + $a
			elif length > 0 and (.[-1][-1] | startswith("--")) then
				.[-1] += [$a]
			else
				. += [[$a]]
			end
		),
		.
	] | transpose
' --args -- "${lookup[@]}" > "$dir/lookup-test.json"

# TODO a *lot* of this could be converted to unit tests via `ocimem` (but then we have to synthesize appropriate edge-case content instead of pulling/copying it, so there's some hurdles to overcome there when we look into doing so)
if [ -n "$doDeploy" ]; then
	# also test "deploy" (optional, disabled by default, because it's a much heavier test)

	"$dir/../.go-env.sh" go build -coverpkg=./... -trimpath -o "$coverage/bin/deploy" ./cmd/deploy

	docker rm -vf meta-scripts-test-registry &> /dev/null || :
	trap 'docker rm -vf meta-scripts-test-registry &> /dev/null || :' EXIT
	docker run --detach --name meta-scripts-test-registry --publish 5000 registry:2
	registryPort="$(DOCKER_API_VERSION=1.41 docker container inspect --format '{{ index .NetworkSettings.Ports "5000/tcp" 0 "HostPort" }}' meta-scripts-test-registry)"

	# apparently Tianon's local system is too good and the registry spins up fast enough, but this needs a small "wait for the registry to be ready" loop for systems like GHA (adding "--cpus 0.01" to the above "docker run" seems to replicate the race reasonably well)
	tries=10
	while [ "$(( tries-- ))" -gt 0 ]; do
		if docker logs meta-scripts-test-registry |& grep -F ' listening on '; then
			break
		fi
		sleep 1
	done

	json="$(jq -n --arg reg "localhost:$registryPort" '
		# explicit base64 data blob
		{
			type: "blob",
			refs: [$reg+"/test@sha256:1a51828d59323e0e02522c45652b6a7a44a032b464b06d574f067d2358b0e9f1"],
			data: "YnVmZnkgdGhlIHZhbXBpcmUgc2xheWVyCg==",
		},

		# JSON data blob
		{
			type: "blob",
			refs: [$reg+"/test@sha256:bdc1ce731138e680ada95089dded3015b8e1570d9a70216867a2a29801a747b3"],
			data: { foo: "bar", baz: [ "buzz", "buzz", "buzz" ] },
		},

		# make sure JSON strings round-trip correctly too
		{
			type: "blob",
			refs: [$reg+"/test@sha256:680c1729a6d4a34f69123f5936cfd4f2cb82a008951241cfc499f9e52996b380"],
			data: ("json string" | @json + "\n" | @base64),
		},

		# test pushing a full, actual image (tianon/true:oci@sha256:9ef42f1d602fb423fad935aac1caa0cfdbce1ad7edce64d080a4eb7b13f7cd9d), all parts
		{
			# config blob
			type: "blob",
			refs: [$reg+"/true"],
			data: "ewoJImFyY2hpdGVjdHVyZSI6ICJhbWQ2NCIsCgkiY29uZmlnIjogewoJCSJDbWQiOiBbCgkJCSIvdHJ1ZSIKCQldCgl9LAoJImNyZWF0ZWQiOiAiMjAyMy0wMi0wMVQwNjo1MToxMVoiLAoJImhpc3RvcnkiOiBbCgkJewoJCQkiY3JlYXRlZCI6ICIyMDIzLTAyLTAxVDA2OjUxOjExWiIsCgkJCSJjcmVhdGVkX2J5IjogImh0dHBzOi8vZ2l0aHViLmNvbS90aWFub24vZG9ja2VyZmlsZXMvdHJlZS9tYXN0ZXIvdHJ1ZSIKCQl9CgldLAoJIm9zIjogImxpbnV4IiwKCSJyb290ZnMiOiB7CgkJImRpZmZfaWRzIjogWwoJCQkic2hhMjU2OjY1YjVhNDU5M2NjNjFkM2VhNmQzNTVmYjk3YzA0MzBkODIwZWUyMWFhODUzNWY1ZGU0NWU3NWMzMTk1NGI3NDMiCgkJXSwKCQkidHlwZSI6ICJsYXllcnMiCgl9Cn0K",
		},
		{
			# layer blob
			type: "blob",
			refs: [$reg+"/true"],
			data: "H4sIAAAAAAACAyspKk1loDEwAAJTU1MwDQTotIGhuQmcDRE3MzM0YlAwYKADKC0uSSxSUGAYoaDe1ceNiZERzmdisGMA8SoYHMB8Byx6HBgsGGA6QDQrmiwyXQPl1cDlIUG9wYaflWEUDDgAAIAGdJIABAAA",
		},
		{
			type: "manifest",
			refs: [ "oci", "latest", (range(0; 10)) | $reg+"/true:\(.)", $reg+"/foo/true:\(.)" ], # test pushing a whole bunch of tags in multiple repos
			lookup: {
				# a few explicit lookup entries for better code coverage (dep calculation during parallelization)
				"sha256:1c51fc286aa95d9413226599576bafa38490b1e292375c90de095855b64caea6": ($reg+"/true"),
				"": ($reg+"/true"),
			},
			data: {
				schemaVersion: 2,
				mediaType: "application/vnd.oci.image.manifest.v1+json",
				config: {
					mediaType: "application/vnd.oci.image.config.v1+json",
					digest: "sha256:25be82253336f0b8c4347bc4ecbbcdc85d0e0f118ccf8dc2e119c0a47a0a486e",
					size: 396,
				},
				layers: [ {
					mediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
					digest: "sha256:1c51fc286aa95d9413226599576bafa38490b1e292375c90de095855b64caea6",
					size: 117,
				} ],
			},
		},

		# test blob mounting between repositories
		{
			type: "blob",
			refs: [$reg+"/test-mount"],
			lookup: { "": ($reg+"/test@sha256:1a51828d59323e0e02522c45652b6a7a44a032b464b06d574f067d2358b0e9f1") },
		},

		# (cross-registry) copy an image from Docker Hub with a blob that is definitely larger than our "BlobSizeWorthHEAD" (and larger than our "manifestSizeLimit" cache limit, so it hits that code too)
		# https://oci.dag.dev/?image=cirros@sha256:6b2d9f5341bce2b1fb29669ff46744a145079ccc6a674849de3a4946ec3d8ffb ("cirros:latest" as of 2024-03-27)
		# https://oci.dag.dev/?image=oisupport/staging-amd64:d5093352bd93df3e9effd7a53bdd46834ac0b1766587a645d4503272597a60dc (the amd64-only index containing that build)
		# .. but first, copy one of the blob explicitly so we test both halves of the conditional
		{
			type: "blob",
			refs: [$reg+"/cirros"],
			lookup: { "": "oisupport/staging-amd64@sha256:6cef03f2716ee8ba76999750aee1a742888ccd0db923be33ff6a410d87f4277d" },
		},
		{
			type: "manifest",
			refs: [$reg+"/cirros"],
			lookup: { "": "oisupport/staging-amd64:34bb44c7d8b6fb7a337fcee0afa7c3a84148e35db6ab83041714c3e6d4c6238b" },
		},
		# and again, but with a manifest bigger than "BlobSizeWorthHEAD"
		# https://oci.dag.dev/?image=tianon/test:screaming-index (big image index, sha256:4077658bc7e39f02f81d1682fe49f66b3db2c420813e43f5db0c53046167c12f)
		{
			type: "manifest",
			refs: [$reg+"/test@sha256:4077658bc7e39f02f81d1682fe49f66b3db2c420813e43f5db0c53046167c12f"],
			lookup: { "sha256:4077658bc7e39f02f81d1682fe49f66b3db2c420813e43f5db0c53046167c12f": "tianon/test" },
		},
		# https://oci.dag.dev/?image=tianon/test:screaming (big image manifest, sha256:96a7a809d1b336011450164564154a5e1c257dc7eb9081e28638537c472ccb90)
		{
			type: "manifest",
			refs: [$reg+"/test@sha256:96a7a809d1b336011450164564154a5e1c257dc7eb9081e28638537c472ccb90"],
			lookup: { "sha256:96a7a809d1b336011450164564154a5e1c257dc7eb9081e28638537c472ccb90": "tianon/test" },
		},
		# again, but this time EVEN BIGGER, just to make sure we test right up to the limit of Docker Hub
		# https://oci.dag.dev/?image=tianon/test:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
		{
			type: "manifest",
			refs: [$reg+"/test:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"],
			lookup: { "": "tianon/test:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee@sha256:73614cc99c500aa4fa061368ed349df24a81844e3c2e6d0c31f290a7c8d73c22" },
		},

		empty
	')" # stored in a variable for easier debugging ("bash -x")

	time "$coverage/bin/deploy" --dry-run --parallel <<<"$json" > "$dir/deploy-dry-run-test.json"
	# port is random, so let's de-randomize it:
	sed -i -e "s/localhost:$registryPort/localhost:3000/g" "$dir/deploy-dry-run-test.json"

	time "$coverage/bin/deploy" --parallel <<<"$json"

	# now that we're done with deploying, a second dry-run should come back empty (this time without parallel to test other codepaths)
	time empty="$("$coverage/bin/deploy" --dry-run <<<"$json")"
	( set -x; test -z "$empty" )

	docker rm -vf meta-scripts-test-registry
	trap - EXIT
fi

# Go tests
"$dir/../.go-env.sh" go test -coverpkg=./... ./... -args -test.gocoverdir="$GOCOVERDIR"

# combine the coverage data into the "legacy" coverage format (understood by "go tool cover") and pre-generate HTML for easier digestion of the data
"$dir/../.go-env.sh" go tool covdata textfmt -i "$GOCOVERDIR" -o "$coverage/coverage.txt"
"$dir/../.go-env.sh" go tool cover -html "$coverage/coverage.txt" -o "$coverage/coverage.html"
"$dir/../.go-env.sh" go tool cover -func "$coverage/coverage.txt"

# also run our "jq" tests (like generating example commands from the "builds.json" we just generated)
"$dir/jq.sh"
