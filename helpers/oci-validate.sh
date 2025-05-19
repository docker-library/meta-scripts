#!/usr/bin/env bash
set -Eeuo pipefail

# given an OCI image layout (https://github.com/opencontainers/image-spec/blob/v1.1.1/image-layout.md), verifies all descriptors as much as possible (digest matches content, size, media types, layer diff_ids, etc)

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

# TODO (recursively?) validate subject descriptors in here somewhere 🤔

# TODO handle objects that *only* exist in the "data" field too 🤔  https://github.com/docker-library/meta-scripts/pull/125#discussion_r2070633122
# maybe descriptor takes a "--data" flag that then returns the input descriptor, but enhanced with a "data" field so the other functions can use that to extract the data instead of relying on files?

descriptor() {
	local file="$1"; shift # "blobs/sha256/xxx"
	local desc; desc="$(cat)"
	local shell
	shell="$(jq <<<"$desc" -L"$BASHBREW_META_SCRIPTS" --slurp --raw-output '
		include "validate";
		include "oci";
		validate_one
		| validate_oci_descriptor
		| (
			@sh "local algo=\(
				.digest
				| split(":")[0]
				| validate_IN(.; "sha256", "sha512") # TODO more algorithms? need more tools on the host
			)",

			@sh "local data=\(
				if has("data") then
					.data
				else " " end # empty string is valid base64 (which we should validate), but spaces are not, so we can use a single space to detect "data not set"
			)",

			empty
		)
	')"
	eval "$shell"
	local digest size dataDigest= dataSize=
	digest="$("${algo}sum" "$file" | cut -d' ' -f1)"
	digest="$algo:$digest"
	size="$(stat --dereference --format '%s' "$file")"
	if [ "$data" != ' ' ]; then
		dataDigest="$(base64 <<<"$data" -d | "${algo}sum" | cut -d' ' -f1)"
		dataDigest="$algo:$dataDigest"
		dataSize="$(base64 <<<"$data" -d | wc --bytes)"
		# TODO *technically* we could get clever here and pass `base64 -d` to something like `tee >(wc --bytes) >(dig="$(sha256sum | cut -d' ' -f1)" && echo "sha256:$dig" && false) > /dev/null` to avoid parsing the base64 twice, but then failure cases are less likely to be caught, so it's safer to simply redecode (and we can't decode into a variable because this might be binary data *and* bash will do newline munging in both directions)
	fi
	jq <<<"$desc" -L"$BASHBREW_META_SCRIPTS" --slurp --arg digest "$digest" --arg size "$size" --arg dataDigest "$dataDigest" --arg dataSize "$dataSize" '
		include "validate";
		validate_one
		| validate_IN(.digest; $digest)
		| validate_IN(.size; $size | tonumber)
		| if has("data") then
			validate(.data;
				$digest == $dataDigest
				and $size == $dataSize
			; "(decoded) data has size \($dataSize) and digest \($dataDigest) (expected \($size) and \($digest))")
		else . end
		| empty
	'
}

# TODO validate config (diff_ids, history, platform - gotta carry *two* levels of descriptors for that, and decompress all the layers 🙊)
# TODO validate provenance/SBOM layer contents?

image() {
	local file="$1"; shift
	echo "image: $file"
	local desc; desc="$(cat)"
	descriptor <<<"$desc" "$file"
	local shell
	shell="$(
		jq <<<"$desc" -L"$BASHBREW_META_SCRIPTS" --slurp --raw-output '
			include "validate";
			include "oci";
			validate_length(.; 2)
			| .[0] as $desc
			| .[1]
			| validate_oci_image({
				imageAttestation: IN($desc.annotations["vnd.docker.reference.type"]; "attestation-manifest"),
			})
			| if $desc then
				validate_IN(.mediaType; $desc.mediaType)
				| validate_IN(.artifactType; $desc.artifactType)
			else . end
			| (
				(
					.config, .layers[]
					| @sh "descriptor <<<\(tojson) \(.digest | "blobs/\(sub(":"; "/"))")"
				),

				empty # trailing comma
			)
		' /dev/stdin "$file"
	)"
	eval "$shell"
}

index() {
	local file="$1"; shift
	echo "index: $file"
	local desc; desc="$(cat)"
	if [ "$desc" != 'null' ]; then
		descriptor <<<"$desc" "$file"
	fi
	local shell
	shell="$(
		jq <<<"$desc" -L"$BASHBREW_META_SCRIPTS" --slurp --raw-output '
			include "validate";
			include "oci";
			validate_length(.; 2)
			| .[0] as $desc
			| .[1]
			| validate_oci_index({
				indexPlatformsOptional: (input_filename == "index.json"),
			})
			| if $desc then
				validate_IN(.mediaType; $desc.mediaType)
				| validate_IN(.artifactType; $desc.artifactType)
			else . end
			| .manifests[]
			| (
				.mediaType
				| if IN(media_types_index) then
					"index"
				elif IN(media_types_image) then
					"image"
				else
					error("UNSUPPORTED MEDIA TYPE: \(.)")
				end
			) + @sh " <<<\(tojson) \(.digest | "blobs/\(sub(":"; "/"))")"
		' /dev/stdin "$file"
	)"
	eval "$shell"
}

index <<<'null' index.json
