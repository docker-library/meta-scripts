#!/usr/bin/env bash
set -Eeuo pipefail

# this is "docker build" but for "Builder: oci-import"
# https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L90-L91

# usage:
#  .../oci-import.sh temp <<<'{"buildId":"...","build":{...},"source":{"entries":[{"Builder":"oci-import","GitCommit":...},...],...}}'

target="$1"; shift # target directory to put OCI layout into (must not exist!)
# stdin: JSON of the full "builds.json" object

[ ! -e "$target" ]
[ -d "$BASHBREW_META_SCRIPTS" ]
[ -s "$BASHBREW_META_SCRIPTS/oci.jq" ]
BASHBREW_META_SCRIPTS="$(cd "$BASHBREW_META_SCRIPTS" && pwd -P)"

# TODO come up with clean ways to harden this against path traversal attacks 🤔 (bad symlinks, "File:" values, etc)
#  - perhaps we run the script in a container? (so the impact of attacks declines to essentially zero)

shell="$(jq -L"$BASHBREW_META_SCRIPTS" --slurp --raw-output '
	include "validate";
	validate_one
	| @sh "buildObj=\(tojson)",
	(
		.source.entries[0] |
		@sh "gitRepo=\(.GitRepo)",
		@sh "gitFetch=\(.GitFetch)",
		@sh "gitCommit=\(.GitCommit)",
		@sh "gitArchive=\(.GitCommit + ":" + (.Directory | if . == "." then "" else . + "/" end))",
		@sh "file=\(.File)",
		empty # trailing comma
	)
')"
eval "$shell"
[ -n "$buildObj" ]
[ -n "$gitRepo" ]
[ -n "$gitFetch" ]
[ -n "$gitCommit" ]
[ -n "$gitArchive" ]
[ -n "$file" ]
export buildObj

# "bashbrew fetch" but in Bash (because we have bashbrew, but not the library file -- we could synthesize a library file instead, but six of one half a dozen of another and this avoids the explicit hard bashbrew dependency)

# initialize "~/.cache/bashbrew/git"
#"gitCache=\"$(bashbrew cat --format '{{ gitCache }}' <(echo 'Maintainers: empty hack (@example)'))\"",
# https://github.com/docker-library/bashbrew/blob/5152c0df682515cbe7ac62b68bcea4278856429f/cmd/bashbrew/git.go#L52-L80
export BASHBREW_CACHE="${BASHBREW_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bashbrew}"
gitCache="$BASHBREW_CACHE/git"
git init --quiet --bare "$gitCache"
_git() { git -C "$gitCache" "$@"; }
_git config gc.auto 0

_commit() { _git rev-parse "$gitCommit^{commit}"; }
if ! _commit &> /dev/null; then
	_git fetch --quiet "$gitRepo" "$gitCommit:" \
		|| _git fetch --quiet "$gitRepo" "$gitFetch:"
fi
_commit > /dev/null

mkdir "$target"

# https://github.com/docker-library/bashbrew/blob/5152c0df682515cbe7ac62b68bcea4278856429f/cmd/bashbrew/git.go#L140-L147 (TODO "bashbrew context" ?)
_git archive --format=tar "$gitArchive" > "$target/oci.tar"
tar --extract --file "$target/oci.tar" --directory "$target"
rm -f "$target/oci.tar"

cd "$target"

# TODO if we normalize everything to an OCI layout, we could have a "standard" script that validates *all* our outputs and not need quite so much here 🤔 (it would even be reasonable to let publishers provide a provenance attestation object like buildkit does, if they so desire, and then we validate that it's roughly something acceptable to us)

# validate oci-layout
jq -L"$BASHBREW_META_SCRIPTS" --slurp '
	include "oci";
	include "validate";

	validate_one
	| validate_oci_layout_file
	| empty
' oci-layout

# validate "File:" (upgrading it to an index if it's not "index.json"), creating a new canonical "index.json" in the process
jq -L"$BASHBREW_META_SCRIPTS" --slurp --tab '
	include "oci";
	include "validate";
	include "meta";

	validate_one

	# https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L116
	| if input_filename != "index.json" then
		{
			schemaVersion: 2,
			mediaType: media_type_oci_index,
			manifests: [ . ],
		}
	else . end

	| .mediaType //= media_type_oci_index # TODO index normalize function?  just force this to be set/valid instead?
	| validate_oci_index
	| validate_length(.manifests; 1) # TODO allow upstream attestation in the future?

	# purge maintainer-provided URLs / annotations (https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L146-L147)
	# (also purge maintainer-provided "data" fields here, since including that in the index is a bigger conversation/decision)
	| del(.manifests[].urls, .manifests[].data)
	| del(.manifests[0].annotations)
	| if .manifests[1].annotations then # TODO have this mean something 😂 (see TODOs above about attestations)
		# filter .manifest[1].annotations to *just* the attestation-related annotations
		.manifests[1].annotations |= with_entries(
			select(.key | IN(
				"vnd.docker.reference.type",
				"vnd.docker.reference.digest",
				empty # trailing comma
			))
		)
	else . end

	| (env.buildObj | fromjson) as $build

	# make sure "platform" is correct
	| .manifests[0].platform = (
		$build
		| .source.arches[.build.arch].platform
	)
	# TODO .manifests[1].platform ?

	# inject our build annotations
	| .manifests[0].annotations += (
		$build
		| build_annotations(.source.entries[0].GitRepo)
	)
	# TODO perhaps, instead, we stop injecting the index annotations via buildkit/buildx and we normalize these two in a separate "inject index annotations" step/script? 🤔

	| normalize_manifest
' "$file" | tee index.json.new
mv -f index.json.new index.json

# TODO "crane validate" is definitely interesting here -- it essentially validates all the descriptors recursively, including diff_ids, but it only supports "remote" or "tarball" (which refers to the *old* "docker save" tarball format), so isn't useful here, but we need to do basically that exact work

# now that "index.json" represents the exact index we want to push, let's push it down into a blob and make a new appropriate "index.json" for "crane push"
# TODO we probably want/need some "traverse/manipulate an OCI layout" helpers 😭
mediaType="$(jq --raw-output '.mediaType' index.json)"
digest="$(sha256sum index.json | cut -d' ' -f1)"
digest="sha256:$digest"
size="$(stat --dereference --format '%s' index.json)"
mv -f index.json "blobs/${digest//://}"
export mediaType digest size
jq -L"$BASHBREW_META_SCRIPTS" --null-input --tab '
	include "oci";
	{
		schemaVersion: 2,
		mediaType: media_type_oci_index,
		manifests: [ {
			mediaType: env.mediaType,
			digest: env.digest,
			size: (env.size | tonumber),
		} ],
	}
	| normalize_manifest
' > index.json
