#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
	set -- --all
fi

# TODO do this for oisupport too! (without arch namespaces; just straight into/from the staging repos)

# TODO drop this from the defaults and set it explicitly in DOI instead (to prevent accidents)
defaultArchNamespaces='
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
	windows-amd64 = winamd64
'
: "${BASHBREW_ARCH_NAMESPACES=$defaultArchNamespaces}"
export BASHBREW_ARCH_NAMESPACES

# let's resolve all the external pins so we can inject those too
libraryDir="${BASHBREW_LIBRARY:-"$HOME/docker/official-images/library"}"
libraryDir="$(readlink -ve "$libraryDir")"
oiDir="$(dirname "$libraryDir")"
externalPinsDir="$oiDir/.external-pins"

externalPins="$("$externalPinsDir/list.sh")"

externalPinsJson='{}'
for tag in $externalPins; do
	f="$("$externalPinsDir/file.sh" "$tag")"
	digest="$(< "$f")"
	externalPinsJson="$(jq <<<"$externalPinsJson" -c --arg tag "${tag#library/}" --arg digest "$digest" '.[$tag] = $digest')"
done

bashbrew cat --build-order --format '
	{{- range $e := .SortedEntries false -}}
		{{- range $a := $e.Architectures -}}
			{{- $archNs := archNamespace $a -}}
			{{- with $e -}}
				{{- $sum := $.ArchGitChecksum $a . -}}
				{{- $file := .ArchFile $a -}}
				{{- $builder := .ArchBuilder $a -}}
				{
					"sourceId": {{ join "\n" $sum $file $builder "" | sha256sum | json }},
					"reproducibleGitChecksum": {{ $sum | json }},
					"entries": [ {
						"GitRepo": {{ .ArchGitRepo $a | json }},
						"GitFetch": {{ .ArchGitFetch $a | json }},
						"GitCommit": {{ .ArchGitCommit $a | json }},
						"Directory": {{ .ArchDirectory $a | json }},
						"File": {{ $file | json }},
						"Builder": {{ $builder | json }},
						"SOURCE_DATE_EPOCH": {{ ($.ArchGitTime $a .).Unix | json }}
					} ],
					"arches": {
						{{ $a | json }}: {
							"tags": {{ $.Tags namespace false . | json }},
							"archTags": {{ if $archNs -}} {{ $.Tags $archNs false . | json }} {{- else -}} [] {{- end }},
							"froms": {{ $.ArchDockerFroms $a . | json }},
							"lastStageFrom": {{ if eq $builder "oci-import" -}}
								{{- /* TODO remove this special case: https://github.com/docker-library/bashbrew/pull/92 */ -}}
								"scratch"
							{{- else -}}
								{{ $.ArchLastStageFrom $a . | json }}
							{{- end }},
							"platformString": {{ (ociPlatform $a).String | json }},
							"platform": {{ ociPlatform $a | json }},
							"parents": { }
						}
					}
				}
			{{- end -}}
		{{- end -}}
	{{- end -}}
' "$@" | jq 3>&1 1>&2 2>&3- -r '
	# https://github.com/jqlang/jq/issues/2063 - "stderr" cannot functionally output a string correctly until jq 1.7+ (which is very very recent), so we hack around it to get some progress output by using Bash to swap stdout and stderr so we can output our objects to stderr and our progress text to stdout and "fix it in post"
	# TODO balk / error at multiple arches entries
	first(.arches | keys_unsorted[]) as $arch
	| .arches[$arch].tags[0] as $tag
	| stderr
	| "\($tag) (\($arch)): \(.sourceId)"
	# TODO if we could get jq 1.7+ for sure, we can drop this entire "jq" invocation and instead have the reduce loop of the following invocation print status strings directly to "stderr"
' | jq -n --argjson pins "$externalPinsJson" '
	def unique_unsorted:
		# https://unix.stackexchange.com/a/738744/153467
		reduce .[] as $a ([]; if IN(.[]; $a) then . else . += [$a] end)
	;
	reduce inputs as $in ({};
		.[$in.sourceId] |=
			if . == null then
				$in
			else
				.arches |= (
					reduce ($in.arches | to_entries[]) as {$key, $value} (.;
						if has($key) then
							# if we already have this architecture, this must be a weird edge case (same sourceId, but different Architectures: lists, for example), so we should validate that the metadata is the same and then do a smart combination of the tags
							if (.[$key] | del(.tags, .archTags)) != ($value | del(.tags, .archTags)) then
								error("duplicate architecture \($key) for \($in.sourceId), but mismatched objects: \(.[$key]) vs \($value)")
							else . end
							| .[$key].tags |= (. + $value.tags | unique_unsorted)
							| .[$key].archTags |= (. + $value.archTags | unique_unsorted)
						else
							.[$key] = $value
						end
					)
				)
				| .entries = (
					reduce $in.entries[] as $inE (.entries;
						# "unique" but without losing ordering (ie, only add entries we do not already have)
						if index($inE) then . else
							. + [ $inE ]
						end
					)
					# then prefer lower SOURCE_DATE_EPOCH earlier, so .entries[0] is the "preferred" (oldest) commit/entry
					| sort_by(.SOURCE_DATE_EPOCH)
					# (this does not lose *significant* ordering because it is a "stable sort", so same SOURCE_DATE_EPOCH gets the same position, unlike "unique_by" which would be destructive, even though it is ultimately what we are emulating with this two-part construction of a new .entries value)
				)
			end
	)
	# TODO a lot of this could be removed/parsed during the above reduce, since it has to parse things in build order anyhow
	# TODO actually, instead, this bit should be a totally separate script so the use case of "combine sources.json files together" works better 👀
	| (
		reduce to_entries[] as $e ({};
			$e.key as $sourceId
			| .[ $e.value.arches[] | .tags[], .archTags[] ] |= (
				.[$e.value.arches | keys[]] |= (
					. + [$sourceId] | unique_unsorted
				)
			)
		)
	) as $tagArches
	| map_values(
		.arches |= with_entries(
			.key as $arch
			| .value.parents = (
				.value.froms | unique_unsorted | map(
					{ (.): {
						sourceId: (
							. as $tag
							| $tagArches[.][$arch]
							| if length > 1 then
								error("too many sourceIds for \($tag) on \($arch): \(.)")
							else .[0] end
						),
						pin: $pins[.],
					} }
				) | add
			)
		)
	)
'
