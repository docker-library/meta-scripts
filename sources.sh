#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$#" -eq 0 ]; then
	set -- --all
fi

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
: "${BASHBREW_ARCH_NAMESPACES:=$defaultArchNamespaces}"
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
	externalPinsJson="$(jq <<<"$externalPinsJson" -c --arg tag "$tag" --arg digest "$digest" '.[$tag] = $digest')"
done

_sha256() {
	sha256sum "$@" | cut -d' ' -f1
}

json="$(
	bashbrew cat --format '
		{{- range $e := .Entries -}}
			{{- range $a := $e.Architectures -}}
				{{- with $e -}}
					{
						"repo": {{ json $.RepoName }},
						"arch": {{ json $a }},
						"archNamespace": {{ json (archNamespace $a) }},
						"gitCache": {{ json gitCache }},
						"Tags": {{ json .Tags }},
						"SharedTags": {{ json .SharedTags }},
						"GitRepo": {{ json (.ArchGitRepo $a) }},
						"GitFetch": {{ json (.ArchGitFetch $a) }},
						"GitCommit": {{ json (.ArchGitCommit $a) }},
						"Directory": {{ json (.ArchDirectory $a) }},
						"File": {{ json (.ArchFile $a) }},
						"Builder": {{ json (.ArchBuilder $a) }},
						"froms": {{ json ($.ArchDockerFroms $a .) }}
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
					"~/source-checksums/tar-scrubber --sha256", # TODO
					empty
				] | join(" | ")
			),
			sourceId: "printf \("%s\\n" | @sh) \"$reproducibleGitChecksum\" \(.File | @sh) \(.Builder | @sh) | _sha256", # the combination of things that might cause a rebuild
			SOURCE_DATE_EPOCH: "git -C \(.gitCache | @sh) show --no-patch --format=format:%ct \(.GitCommit | @sh)",
		}
		| to_entries
		| [
			"printf >&2 \("%s (%s): " | @sh) \($e.repo + ":" + $e.Tags[0]) \($e.arch)",
			empty
		]
		+ map(.key + "=\"$(" + .value + ")\"")
		+ [
			"export \(map(.key) | join(" "))",
			"printf >&2 \("%s\\n" | @sh) \"$sourceId\"",
			(
				$e | {
					tags: (.Tags | map($e.repo + ":" + .)),
					sharedTags: (.SharedTags | map($e.repo + ":" + .)),
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
							ns: .archNamespace,
							froms: .froms,
						},
					},
				} as $obj
				| "jq <<<\($obj | tojson | @sh) -c \(".sourceId = env.sourceId | .reproducibleGitChecksum = env.reproducibleGitChecksum | .entry.SOURCE_DATE_EPOCH = (env.SOURCE_DATE_EPOCH | tonumber)" | @sh)" # TODO
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
				.tags |= (. + $in.tags | unique_unsorted)
				| .sharedTags |= (. + $in.sharedTags | unique_unsorted)
				| .arches += $in.arches # TODO error on duplicates here
				| if .entry.SOURCE_DATE_EPOCH > $in.entry.SOURCE_DATE_EPOCH then
					.entry = $in.entry
				else . end
			end
		)
	)
	| (
		reduce to_entries[] as $e ({};
			$e.key as $sourceId
			| .[$e.value.tags + $e.value.sharedTags | .[]] |= (
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
