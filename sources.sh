#!/usr/bin/env bash
set -Eeuo pipefail

cacheFile=
if [ "$#" -gt 0 ]; then
	case "$1" in
		--cache-file=*)
			cacheFile="${1#*=}"
			shift
			;;
		--cache-file)
			shift
			cacheFile="$1"
			shift
			;;
	esac
fi

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

bashbrew_cat() {
	local HEAVY_CALC=''
	if [ "$1" = '--do-heavy' ]; then
		shift
		HEAVY_CALC=1
	fi

	bbCat=( bashbrew cat --build-order --format '
		{{- range $e := .SortedEntries false -}}
			{{- range $a := $e.Architectures -}}
				{{- $archNs := archNamespace $a -}}
				{{- with $e -}}
					{{- $file := .ArchFile $a -}}
					{{- $builder := .ArchBuilder $a -}}
					{
					{{- if getenv "HEAVY_CALC" -}}
						{{- $sum := $.ArchGitChecksum $a . }}
						"sourceId": {{ join "\n" $sum $file $builder "" | sha256sum | json }},
						"reproducibleGitChecksum": {{ $sum | json }},
					{{- else }}
						"sourceId": null,
						"reproducibleGitChecksum": null,
					{{- end }}
						"entries": [ {
							"GitRepo": {{ .ArchGitRepo $a | json }},
							"GitFetch": {{ .ArchGitFetch $a | json }},
							"GitCommit": {{ .ArchGitCommit $a | json }},
							"Directory": {{ .ArchDirectory $a | json }},
							"File": {{ $file | json }},
							"Builder": {{ $builder | json }},
							"SOURCE_DATE_EPOCH": {{ if getenv "HEAVY_CALC" -}} {{ ($.ArchGitTime $a .).Unix | json }} {{- else -}} null {{- end }}
						} ],
						"arches": {
							{{ $a | json }}: {
								"tags": {{ $.Tags namespace false . | json }},
								"archTags": {{ if $archNs -}} {{ $.Tags $archNs false . | json }} {{- else -}} [] {{- end }},
								"froms": {{ if getenv "HEAVY_CALC" -}} {{ $.ArchDockerFroms $a . | json }} {{- else -}} [] {{- end }},
								"lastStageFrom": {{ if getenv "HEAVY_CALC" -}} {{ $.ArchLastStageFrom $a . | json }} {{- else -}} null {{- end }},
								"platformString": {{ (ociPlatform $a).String | json }},
								"platform": {{ ociPlatform $a | json }},
								"parents": { }
							}
						}
					}
				{{- end -}}
			{{- end -}}
		{{- end -}}
	' "$@" )
	if [ -n "$HEAVY_CALC" ]; then
		HEAVY_CALC="$HEAVY_CALC" "${bbCat[@]}" | jq 3>&1 1>&2 2>&3- -r '
			# https://github.com/jqlang/jq/issues/2063 - "stderr" cannot functionally output a string correctly until jq 1.7+ (which is very very recent), so we hack around it to get some progress output by using Bash to swap stdout and stderr so we can output our objects to stderr and our progress text to stdout and "fix it in post"
			# TODO balk / error at multiple arches entries
			first(.arches | keys_unsorted[]) as $arch
			| .arches[$arch].tags[0] as $tag
			| stderr
			| "\($tag) (\($arch)): \(.sourceId)"
			# TODO if we could get jq 1.7+ for sure, we can drop this entire "jq" invocation and instead have the reduce loop of the following invocation print status strings directly to "stderr"
		' | jq -n '[ inputs ]'
	else
		"${bbCat[@]}" | jq -n '[ inputs ]'
	fi
}

# merges heavy-to-calculate data from the second json input (list or map of sources) into the first json input (list of sources)
# uses "mostlyUniqueBitsSum" as a rough analogue for sourceId to correlate data between the input lists
#  (sourceId, reproducibleGitChecksum, SOURCE_DATE_EPOCH, froms, lastStageFrom)
# echo '[{}, {},...] [{extraData},...]' | mergeData
mergeData() {
	jq --slurp '
		def mostlyUniqueBitsSum($arch):
			{
				GitCommit,
				Directory,
				File,
				Builder,

				# "sourceId" normally does not include arch, but we have to because of the complexity below in needing to match/extract "froms" and "lastStageFrom" correctly since one or both sides of the `mergeData` input is always the uncombined version and we will otherwise lose/clobber data if our fake sourceId is not as granular as our input data
				$arch,
			} | @json
		;
		(
			[
				.[1][] as $source
				| $source.arches
				| keys[] as $arch
				| $source.entries[]
				| {
					key: mostlyUniqueBitsSum($arch),
					value: {
						entry: .,
						source: $source,
					}
				}
			] | from_entries
		) as $cacheFile
		| .[0]
		| map(
			. as $it
			| (
				$it.arches | keys_unsorted
				# ensure input data is just one architecture per source
				| if length != 1 then
					error("too many architectures in input list: \($it)")
				else . end
			)[0] as $arch
			| (
				# match an item by the unique bits that we have
				$cacheFile[
					# because it is one architecture per source, it will only have one entry (verfied below)
					$it.entries[0]
					| mostlyUniqueBitsSum($arch)
				]
				| select(.source.sourceId)
				| .entry as $entry
				| .source
				| $it * {
					# this might pull in "null" values from the cache if we change the format, but they will get fixed on the second round of "mergeData"
					sourceId,
					reproducibleGitChecksum,
					arches: {
						($arch): {
							froms: .arches[$arch].froms,
							lastStageFrom: .arches[$arch].lastStageFrom,
						},
					},
				}
				# because it is one architecture per source, it should also only have one entry
				| if .entries | length != 1 then
					error("more than one entry in an input source: \(.)")
				else . end
				| .entries[0].SOURCE_DATE_EPOCH = $entry.SOURCE_DATE_EPOCH
			) // $it
		)
	'
}

sources=
if [ -s "$cacheFile" ]; then
	sources="$({ bashbrew_cat "$@"; cat "$cacheFile"; } | mergeData)"
	heavy="$(
		jq <<<"$sources" -r '
			map(
				select(any( ..; type == "null" or (type == "array" and length == 0) ))
				| first(.arches[].tags[])
				| @sh
			) | unique
			| join(" ")
		'
	)"
	eval "heavy=( $heavy )"

	# items missing sourceId/reproducibleGitChecksum (i.e. missing from cache) need to use bashbrew cat to sum files from build context
	if [ "${#heavy[@]}" -gt 0 ]; then
		# TODO fetch heavy lookup data only for specific architectures
		sources="$({ cat <<<"$sources"; bashbrew_cat --do-heavy "${heavy[@]}"; } | mergeData)"
	fi
else
	sources="$(bashbrew_cat --do-heavy "$@")"
fi

jq <<<"$sources" --argjson pins "$externalPinsJson" '
	def unique_unsorted:
		# https://unix.stackexchange.com/a/738744/153467
		reduce .[] as $a ([]; if IN(.[]; $a) then . else . += [$a] end)
	;
	def meld($o):
		# recursive merge of objects like "*", but also append lists (uniquely) instead of replace
		# https://stackoverflow.com/a/53666584, but with lists unique-ified and less work being done
		if type == "object" and ($o | type) == "object" then
			reduce ($o | keys_unsorted[]) as $k (.;
				.[$k] |= meld($o[$k])
			)
		elif type == "array" and ($o | type) == "array" then
			. + $o
			| unique_unsorted
		elif $o == null then
			.
		else
			$o
		end
	;
	(
		# creating a lookup of .[tag][arch] to a list of sourceIds
		[
			.[] as $s
			| ( $s.arches[] | .tags[], .archTags[] )
			| {
				key: .,
				# this happens pre-arches-merge, so it is only one arch
				value: { ($s.arches | keys[]): [$s.sourceId] },
			}
		]
		# do not try to code golf this to one reduce without from_entries or group_by; doing ".[xxx] |=" on the *full* unordered object gets orders of magnitude slower
		| group_by(.key)
		| [
			# many little reduces based on same key (group_by^), instead of one very big and expensive
			.[] | reduce .[] as $r ({}; meld($r))
		]
		| from_entries
	) as $tagArches
	| reduce .[] as $in ({};
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
