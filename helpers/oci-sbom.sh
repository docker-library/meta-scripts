#!/usr/bin/env bash
set -Eeuo pipefail

# this will trick BuildKit into generating an SBOM for us, then inject it into our OCI layout

# usage:
#  .../oci-sbom.sh input-oci output-oci

input="$1"; shift # input OCI layout (single image)
output="$1"; shift # output OCI layout
# stdin: JSON of the full "builds.json" object

[ -n "$BASHBREW_BUILDKIT_SBOM_GENERATOR" ]
[ -d "$input" ]
[ ! -e "$output" ]
[ -d "$BASHBREW_META_SCRIPTS" ]
[ -s "$BASHBREW_META_SCRIPTS/oci.jq" ]
input="$(cd "$input" && pwd -P)"
BASHBREW_META_SCRIPTS="$(cd "$BASHBREW_META_SCRIPTS" && pwd -P)"

shell="$(jq -L"$BASHBREW_META_SCRIPTS" --slurp --raw-output '
	include "validate";
	validate_one
	| @sh "buildObj=\(tojson)",
		@sh "SOURCE_DATE_EPOCH=\(.source.entries[0].SOURCE_DATE_EPOCH)",
		@sh "platform=\(.source.arches[.build.arch].platformString)",
		empty # trailing comma
')"
eval "$shell"
[ -n "$buildObj" ]
[ -n "$SOURCE_DATE_EPOCH" ]
[ -n "$platform" ]
export buildObj

mkdir "$output"
cd "$output"

imageIndex="$(jq -L"$BASHBREW_META_SCRIPTS" --raw-output '
	include "oci";
	include "validate";
	validate_oci_index({ indexPlatformsOptional: true })
	| validate_length(.manifests; 1)
	| validate_IN(.manifests[0].mediaType; media_types_index)
	| .manifests[0].digest
' "$input/index.json")"

shell="$(jq -L"$BASHBREW_META_SCRIPTS" --raw-output '
	include "oci";
	include "validate";
	validate_oci_index
	| validate_length(.manifests; 1) # TODO technically it would be OK if we had provenance here 🤔 (it just is harder to "merge" 2x provenance than to append 1x)
	| validate_IN(.manifests[0].mediaType; media_types_image)
	# TODO should we pull "$platform" from .manifests[0].platform instead of the build object above? (making the build object input optional would make this script easier to test by hand; so maybe just if we did not get it from build?)
	| @sh "export imageManifest=\(.manifests[0].digest)",
		empty # trailing comma
' "$input/blobs/${imageIndex/://}")"
eval "$shell"

copyBlobs=( "$imageManifest" )
shell="$(jq -L"$BASHBREW_META_SCRIPTS" --raw-output '
	include "oci";
	validate_oci_image
	| "copyBlobs+=( \(
		[
			.config.digest,
			.layers[].digest
			| @sh
		]
		| join(" ")
	) )"
' "$input/blobs/${imageManifest/://}")"
eval "$shell"

args=(
	--progress=plain
	--load=false --provenance=false # explicitly disable a few features we want to avoid
	--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=all # disable linting (https://github.com/moby/buildkit/pull/4962)
	--sbom=generator="$BASHBREW_BUILDKIT_SBOM_GENERATOR"
	--output "type=oci,tar=false,dest=."
	# TODO also add appropriate "--tag" lines (which would give us a mostly correct "subject" block in the generated SBOM, but we'd then need to replace instances of $sbomImageManifest with $imageManifest for their values to be correct)
	--platform "$platform"
	--build-context "fake=oci-layout://$input@$imageManifest"
	'-'
)
docker buildx build "${args[@]}" <<<'FROM fake'

for blob in "${copyBlobs[@]}"; do
	cp --force --dereference --link "$input/blobs/${blob/://}" "blobs/${blob/://}"
done

sbomIndex="$(jq -L"$BASHBREW_META_SCRIPTS" --raw-output '
	include "oci";
	include "validate";
	validate_oci_index({ indexPlatformsOptional: true })
	| validate_length(.manifests; 1)
	| validate_IN(.manifests[0].mediaType; media_types_index)
	| .manifests[0].digest
' index.json)"

shell="$(jq -L"$BASHBREW_META_SCRIPTS" --raw-output '
	include "oci";
	include "validate";
	validate_oci_index
	| validate_length(.manifests; 2)
	| validate_IN(.manifests[].mediaType; media_types_image)
	| validate_IN(.manifests[1].annotations["vnd.docker.reference.type"]; "attestation-manifest")
	| .manifests[0].digest as $fakeImageDigest
	| validate_IN(.manifests[1].annotations["vnd.docker.reference.digest"]; $fakeImageDigest)
	| @sh "sbomManifest=\(.manifests[1].digest)",
		# TODO (see "--tag" TODO above) @sh "sbomImageManifest=\(.manifests[0].digest)",
		@sh "export sbomManifestDesc=\(
			.manifests[1]
			| .annotations["vnd.docker.reference.digest"] = env.imageManifest
			| tojson
		)",
		empty # trailing comma
' "blobs/${sbomIndex/://}")"
eval "$shell"

jq -L"$BASHBREW_META_SCRIPTS" --tab '
	include "oci";
	# we already validate this exact object above, so we do not need to revalidate here
	.manifests[1] = (env.sbomManifestDesc | fromjson) # TODO merge provenance, if applicable (see TODOs above)
	| normalize_manifest
' "$input/blobs/${imageIndex/://}" | tee index.json

# (this is an exact copy of the end of "oci-import.sh" 😭)
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

# TODO move this further out
"$BASHBREW_META_SCRIPTS/helpers/oci-validate.sh" .
