#!/usr/bin/env bash
set -Eeuo pipefail

json="$1"

: "${BASHBREW_STAGING_TEMPLATE:=oisupport/staging-ARCH:BUILD}"
export BASHBREW_STAGING_TEMPLATE

shell="$(jq -r '
	[
		"set -- \(keys_unsorted | map(@sh) | join(" "))",
		"declare -A sources=(",
		(
			to_entries[]
			| "\t[\(.key | @sh)]=\(.value | tojson | @sh)"
		),
		")"
	] | join("\n")
' "$json")"
eval "$shell"

_resolveRemoteArch() {
	local img="$1"; shift

	local arches
	if ! arches="$(bashbrew remote arches --json "$img" 2>/dev/null)"; then # TODO somehow differentiate errors like 404 / 403, "insufficient_scope" from other bashbrew errors here so we can stop eating stderr
		printf 'null'
		return
	fi

	echo "$arches"
}

# resolve an image reference to an architecture-specific imageId (digest of the image manifest)
_resolve() {
	local img="$1"; shift
	local arch="$1"; shift
	local bashbrewRemoteArches="$1"; shift

	if [ "$bashbrewRemoteArches" = 'null' ]; then
		printf 'null'
		return
	fi

	jq <<<"$bashbrewRemoteArches" -c --arg arch "$arch" --arg img "$img" '
		if .arches | has($arch) then
			($img | sub("@[^@]+$"; "")) as $base
			| {
				# ref + descriptor of the arch-specific manifest
				manifest: (
					# TODO warn/error on multiple entries for $arch?
					.arches[$arch][0]
					| {
						ref: ($base + "@" + .digest),
						desc: .,
					}
				),
				# ref + descriptor of the index
				index: {
					ref: ($base + "@" + .desc.digest),
					desc: .desc,
				},
			}
			| if .index.desc.digest == .manifest.desc.digest then
				del(.index)
			else . end
		else null end
	' || exit 1
}

declare -A imageArchResolved=(
	#["image"]="{...}" # JSON result of bashbrew remote arches
)

# for each sourceId, try to calculate a buildId, then do a registry lookup to get an imageId
# then, anything that has a calculated buildId but *not* an imageId is something that needs a build
# (and each buildId needs to include the imageIds of all the parent images -- without those, the buildId is invalid / impossible to calculate, which forces us to build everything in order)
declare -A sourceArchResolved=(
	#["$sourceId-$arch"]="xxx/staging-xxx:$buildId@sha256:xxx"
)
builds='{}'
for sourceId; do
	obj="${sources["$sourceId"]}"

	shell="$(jq <<<"$obj" -r '
		[
			"tag=\(.allTags[0] | @sh)",
			( .arches |
				"arches=( \(keys_unsorted | map(@sh) | join(" ")) )",
				"declare -A archObjs=(",
				(
					to_entries[]
					| "\t[\(.key | @sh)]=\(.value | tojson | @sh)"
				),
				")"
			)
		] | join("\n")
	')"
	eval "$shell"

	printf >&2 '%s (%s):\n' "$sourceId" "$tag"

	for arch in "${arches[@]}"; do
		archObj="${archObjs["$arch"]}"

		printf >&2 ' -> %s: ' "$arch"

		buildIdParts="$(jq -nc --arg sourceId "$sourceId" --arg arch "$arch" '
			{
				sourceId: $sourceId,
				arch: $arch,
				parents: {},

				# this is included for data tracking purposes, but is not part of the final "buildId" calculation like the above fields are
				resolvedParents: {},
				# (we only include parent descriptor in the buildId so that EOL parents do not cause a build cache bust)
			}
		')"

		shell="$(jq <<<"$archObj" -r '
			[
				"parents=(",
				(
					.parents
					| to_entries[]
					| select(.key != "scratch")
					| { from: .key } + .value
					| tojson | @sh
					| "\t" + .
				),
				")"
			] | join("\n")
		')"
		eval "$shell"

		missingParents=0
		for parent in "${parents[@]}"; do
			lookup="$(jq <<<"$parent" -r '
				if .sourceId then
					.sourceId
				elif .pin then
					.from + "@" + .pin
				else
					# cases like "FROM alpine:3.11" will fall back here (unsupported/deprecated/"naughty" base images)
					.from
				end
			')"

			# if "$lookup" is a valid/known sourceId, we should look up the (pre-resolved) imageId for it
			if [ -n "$lookup" ] && [ -n "${sources["$lookup"]:+x}" ]; then
				resolved="${sourceArchResolved["$lookup-$arch"]:-}"
			elif [ -n "$lookup" ]; then
				if [ -z "${imageArchResolved["$lookup"]:+x}" ]; then
					remoteArches="$(_resolveRemoteArch "$lookup")"
					imageArchResolved["$lookup"]="$remoteArches"
				fi

				resolved="$(_resolve "$lookup" "$arch" "${imageArchResolved["$lookup"]}")"
			else
				resolved=
			fi
			: "${resolved:=null}"

			buildIdParts="$(
				jq <<<"$buildIdParts" -c \
					--argjson parent "$parent" \
					--argjson resolved "$resolved" \
					'
						.resolvedParents[$parent.from] = $resolved
						| .parents[$parent.from] = $resolved.manifest?.desc?.digest?
					'
			)"

			if [ "$resolved" = 'null' ] || [ -z "$resolved" ]; then
				(( missingParents++ )) || :
			fi
		done

		# if we're missing *any* parents, we cannot have a buildId
		if [ "$missingParents" = 0 ]; then
			buildIdJson="$(jq <<<"$buildIdParts" -c 'del(.resolvedParents)')" # see notes above (where buildIdParts is first defined)
			buildId="$(sha256sum <<<"$buildIdJson" | cut -d' ' -f1)" # see notes above (where buildIdParts is first defined)
			printf >&2 '%s\n' "$buildId"

			img="$BASHBREW_STAGING_TEMPLATE"
			img="${img//BUILD/$buildId}"
			[ "$img" != "$BASHBREW_STAGING_TEMPLATE" ] # BUILD is required, for proper uniqueness (ARCH is optional)
			img="${img//ARCH/$arch}"

			if [ -z "${imageArchResolved["$img"]:+x}" ]; then
				remoteArches="$(_resolveRemoteArch "$img")"
				imageArchResolved["$img"]="$remoteArches"
			fi

			resolved="$(_resolve "$img" "$arch" "${imageArchResolved["$img"]}")"
			: "${resolved:=null}"
			sourceArchResolved["$sourceId-$arch"]="$resolved"
			builds="$(
				jq <<<"$builds" \
					--argjson source "$obj" \
					--argjson buildIdParts "$buildIdParts" \
					--arg buildId "$buildId" \
					--arg img "$img" \
					--argjson resolved "$resolved" \
					'
						# TODO error out if $buildId already exists somehow (should be impossible)
						.[$buildId] = {
							buildId: $buildId,
							build: ({
								img: $img,
								resolved: $resolved,
							} + $buildIdParts),
							source: (
								$source
								| .arches |= (
									(keys_unsorted - [ $buildIdParts.arch ]) as $otherArches
									| del(.[$otherArches[]])
								)
							),
						}
					'
			)"
		else
			printf >&2 'not yet!\n'
		fi
	done
done
jq <<<"$builds" .
