#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
	set -- --all
fi

# TODO do this for oisupport too! (without arch namespaces; just straight into/from the staging repos)

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
' # TODO
: "${BASHBREW_ARCH_NAMESPACES=$defaultArchNamespaces}"
export BASHBREW_ARCH_NAMESPACES

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"
if [ "$dir/tar-scrubber.go" -nt "$dir/tar-scrubber" ]; then
	# TODO this should probably live somewhere else (bashbrew?)
	{
		echo "building '$dir/tar-scrubber' from 'tar-scrubber.go'"
		user="$(id -u):$(id -g)"
		args=(
			--rm
			--user "$user"
			--mount "type=bind,src=$dir,dst=/app"
			--workdir /app
			--tmpfs /tmp
			--env HOME=/tmp
			--env CGO_ENABLED=0
			golang:1.20
			go build -v -o tar-scrubber tar-scrubber.go
		)
		docker run "${args[@]}"
		ls -l "$dir/tar-scrubber"
	} >&2
fi
[ -x "$dir/tar-scrubber" ]
export tarScrubber="$dir/tar-scrubber"

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

_sha256() {
	sha256sum "$@" | cut -d' ' -f1
}

json="$(
	bashbrew cat --build-order --format '
		{{- range $e := .Entries -}}
			{{- range $a := $e.Architectures -}}
				{{- $archNs := archNamespace $a -}}
				{{- with $e -}}
					{
						"repo": {{ $.RepoName | json }},
						"arch": {{ $a | json }},
						"platformString": {{ (ociPlatform $a).String | json }},
						"platform": {{ ociPlatform $a | json }},
						"gitCache": {{ gitCache | json }},
						"tags": {{ $.Tags namespace false . | json }},
						"archTags": {{ if $archNs -}} {{ $.Tags $archNs false . | json }} {{- else -}} [] {{- end }},
						"GitRepo": {{ .ArchGitRepo $a | json }},
						"GitFetch": {{ .ArchGitFetch $a | json }},
						"GitCommit": {{ .ArchGitCommit $a | json }},
						"Directory": {{ .ArchDirectory $a | json }},
						"File": {{ .ArchFile $a | json }},
						"Builder": {{ .ArchBuilder $a | json }},
						"froms": {{ $.ArchDockerFroms $a . | json }}
					}
				{{- end -}}
			{{- end -}}
		{{- end -}}
	' "$@"
)"

shell="$(
	jq <<<"$json" -r '
		. as $e
		| {
			reproducibleGitChecksum: (
				[
					# TODO do this inside bashbrew? (could then use go-git to make an even more determistic tarball instead of munging Git afterwards, and could even do things like munge the Dockerfile to remove no-rebuild variance like comments and non-COPY-ed files)
					"git -C \(.gitCache | @sh) archive --format=tar \(.GitCommit + ":" + (.Directory | if . == "." then "" else . + "/" end) | @sh)",
					"\(env.tarScrubber | @sh) --sha256",
					empty
				] | join(" | ")
			),
			sourceId: "printf \("%s\\n" | @sh) \"$reproducibleGitChecksum\" \(.File | @sh) \(.Builder | @sh) | _sha256", # the combination of things that might cause a rebuild # TODO consider making this a compressed JSON object like buildId
			SOURCE_DATE_EPOCH: "git -C \(.gitCache | @sh) show --no-patch --format=format:%ct \(.GitCommit | @sh)",
		}
		| to_entries
		| [
			"printf >&2 \("%s (%s): " | @sh) \($e.tags[0]) \($e.arch)",
			empty
		]
		+ map(.key + "=\"$(" + .value + ")\"")
		+ [
			"export \(map(.key) | join(" "))",
			"printf >&2 \("%s\\n" | @sh) \"$sourceId\"",
			(
				$e
				| {
					allTags: (.tags + .archTags),
					entry: {
						GitRepo: .GitRepo,
						GitFetch: .GitFetch,
						GitCommit: .GitCommit,
						Directory: .Directory,
						File: .File,
						Builder: .Builder,
					},
					arches: {
						(.arch): {
							tags: .tags,
							archTags: .archTags,
							froms: .froms,
							platformString: .platformString,
							platform: .platform,
						},
					},
				} as $obj
				| "jq <<<\($obj | tojson | @sh) -c \("{ sourceId: env.sourceId, reproducibleGitChecksum: env.reproducibleGitChecksum } + . | .entry.SOURCE_DATE_EPOCH = (env.SOURCE_DATE_EPOCH | tonumber)" | @sh)"
			),
			empty
		]
		| join("\n")
	'
)"
json="$(set -Eeuo pipefail; eval "$shell")"
jq <<<"$json" -s --argjson pins "$externalPinsJson" '
	def unique_unsorted:
		# https://unix.stackexchange.com/a/738744/153467
		reduce .[] as $a ([]; if IN(.[]; $a) then . else . += [$a] end)
	;
	reduce .[] as $in ({};
		.[$in.sourceId] |= (
			if . == null then
				$in
			else
				.allTags |= (. + $in.allTags | unique_unsorted)
				| .arches |= (
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
				| if .entry.SOURCE_DATE_EPOCH > $in.entry.SOURCE_DATE_EPOCH then
					# smallest SOURCE_DATE_EPOCH wins in the face of duplicates for a given sourceId
					.entry = $in.entry
				else . end
			end
		)
	)
	| (
		reduce to_entries[] as $e ({};
			$e.key as $sourceId
			| .[$e.value.allTags[]] |= (
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
