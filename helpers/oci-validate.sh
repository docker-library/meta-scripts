#!/usr/bin/env bash
set -Eeuo pipefail

# given an OCI image layout (https://github.com/opencontainers/image-spec/blob/v1.1.1/image-layout.md), verifies all descriptors as much as possible (digest matches content, size, some media types, layer diff_ids, etc)

layout="$1"; shift

[ -d "$layout" ]
[ -d "$BASHBREW_META_SCRIPTS" ]
[ -s "$BASHBREW_META_SCRIPTS/oci.jq" ]
BASHBREW_META_SCRIPTS="$(cd "$BASHBREW_META_SCRIPTS" && pwd -P)"

cd "$layout"

# validate oci-layout
echo 'oci-layout'
jq -L"$BASHBREW_META_SCRIPTS" --slurp '
	include "oci";
	include "validate";

	validate_one
	| validate_oci_layout_file
	| empty
' oci-layout

# TODO this is all rubbish; it needs more thought (the jq functions it invokes are pretty solid now though)

descriptor() {
	local file="$1"; shift # "blobs/sha256/xxx"
	echo "blob: $file"
	local digest="$1"; shift # "sha256:xxx"
	local size="$1"; shift # "123"
	local algo="${digest%%:*}" # sha256
	local hash="${digest#$algo:}" # xxx
	local diskSize
	[ "$algo" = 'sha256' ] # TODO error message
	diskSize="$(stat --dereference --format '%s' "$file")"
	[ "$size" = "$diskSize" ] # TODO error message
	"${algo}sum" <<<"$hash *$file" --check --quiet --strict -
}

images() {
	echo "image: $*"
	local shell
	shell="$(
		jq -L"$BASHBREW_META_SCRIPTS" --arg expected "$#" --slurp --raw-output '
			include "validate";
			include "oci";
			# TODO technically, this would pass if one file is empty and another file has two documents in it (since it is counting the total), so that is not great, but probably is not a real problem
			validate_length(.; $expected | tonumber)
			| map(validate_oci_image)
			| (
				(
					.[].config, .[].layers[]
					| @sh "descriptor \("blobs/\(.digest | sub(":"; "/"))") \(.digest) \(.size)"
					# TODO data?
				),

				empty # trailing comma
			)
		' "$@"
	)"
	eval "$shell"
}

# TODO pass descriptor values down so we can validate that they match (.mediaType, .artifactType, .platform across *two* levels index->manifest->config), similar to .data
# TODO disallow urls completely?

indexes() {
	echo "index: $*"
	local shell
	shell="$(
		jq -L"$BASHBREW_META_SCRIPTS" --arg expected "$#" --slurp --raw-output '
			include "validate";
			include "oci";
			# TODO technically, this would pass if one file is empty and another file has two documents in it (since it is counting the total), so that is not great, but probably is not a real problem
			validate_length(.; $expected | tonumber)
			| map(validate_oci_index)
			| (
				(
					.[].manifests[]
					| @sh "descriptor \("blobs/\(.digest | sub(":"; "/"))") \(.digest) \(.size)"
					# TODO data?
				),

				(
					[ .[].manifests[] | select(IN(.mediaType; media_types_image)) | .digest ]
					| if length > 0 then
						"images \(map("blobs/\(sub(":"; "/"))" | @sh) | join(" "))"
					else empty end
				),

				(
					[ .[].manifests[] | select(IN(.mediaType; media_types_index)) | .digest ]
					| if length > 0 then
						"indexes \(map("blobs/\(sub(":"; "/"))" | @sh) | join(" "))"
					else empty end
				),

				empty # trailing comma
			)
		' "$@"
	)"
	eval "$shell"
}

indexes index.json
