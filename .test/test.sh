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

set -- docker:cli docker:dind docker:windowsservercore notary busybox:latest # a little bit of Windows, a little bit of Linux, a little bit of multi-stage, a little bit of oci-import
# (see "library/" and ".external-pins/" for where these come from / are hard-coded for consistent testing purposes)
# NOTE: we are explicitly *not* pinning "golang:1.19-alpine3.16" so that this also tests unpinned parent behavior (that image is deprecated so should stay unchanging)

time bashbrew fetch "$@"

time "$dir/../sources.sh" "$@" > "$dir/sources.json"

coverage="$dir/.coverage"
rm -rf "$coverage/GOCOVERDIR" "$coverage/bin"
mkdir -p "$coverage/GOCOVERDIR" "$coverage/bin"
export GOCOVERDIR="${GOCOVERDIR:-"$coverage/GOCOVERDIR"}"

time "$coverage/builds.sh" --cache "$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"
[ -s "$coverage/bin/builds" ] # just to make sure it actually did build/use an appropriate binary 🙈

# test again, but with "--cache=..." instead of "--cache ..." (which also lets us delete the cache and get slightly better coverage reports at the expense of speed / Hub requests)
time "$coverage/builds.sh" --cache="$dir/cache-builds.json" "$dir/sources.json" > "$dir/builds.json"

# test "lookup" code for more edge cases
"$dir/../.go-env.sh" go build -cover -trimpath -o "$coverage/bin/lookup" ./cmd/lookup
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

	"$dir/../.go-env.sh" go build -cover -trimpath -o "$coverage/bin/deploy" ./cmd/deploy

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

	"$coverage/bin/deploy" <<<"$json"

	docker rm -vf meta-scripts-test-registry
	trap - EXIT
fi

# Go tests
"$dir/../.go-env.sh" go test -cover ./... -args -test.gocoverdir="$GOCOVERDIR"

# combine the coverage data into the "legacy" coverage format (understood by "go tool cover") and pre-generate HTML for easier digestion of the data
"$dir/../.go-env.sh" go tool covdata textfmt -i "$GOCOVERDIR" -o "$coverage/coverage.txt"
"$dir/../.go-env.sh" go tool cover -html "$coverage/coverage.txt" -o "$coverage/coverage.html"
"$dir/../.go-env.sh" go tool cover -func "$coverage/coverage.txt"

# also run our "jq" tests (like generating example commands from the "builds.json" we just generated)
"$dir/jq.sh"
