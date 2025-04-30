include "sort";
include "validate";

# TODO maybe this helper should be part of sort.jq? 👀
def _sort_by_key(stuff):
	to_entries
	| sort_by(.key | stuff)
	| from_entries
;
def _sort_by_key: _sort_by_key(.);

# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md#:~:text=generate%20an%20error.-,platform%20object,-This%20OPTIONAL%20property

# input: OCI "platform" object (see link above)
# output: normalized OCI "platform" object
def normalize_platform:
	.variant = (
		{
			# https://github.com/golang/go/blob/e85968670e35fc24987944c56277d80d7884e9cc/src/cmd/dist/build.go#L145-L185
			# https://github.com/golang/go/blob/e85968670e35fc24987944c56277d80d7884e9cc/src/internal/buildcfg/cfg.go#L58-L175
			# https://github.com/containerd/platforms/blob/db76a43eaea9a004a5f240620f966b0081123884/database.go#L75-L109
			# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md#platform-variants

			#"amd64/": "v1", # TODO https://github.com/opencontainers/image-spec/pull/1172
			"arm/": "v7",
			"arm64/": "v8", # TODO v8.0 ?? https://github.com/golang/go/issues/60905 -> https://go-review.googlesource.com/c/go/+/559555/comment/e2049987_1bc3a065/ (no support for vX.Y in containerd; likely nowhere else either); https://github.com/opencontainers/image-spec/pull/1172
			#"ppc64le/": "power8", # TODO https://github.com/opencontainers/image-spec/pull/1172
			#"riscv64/": "rva20u64", # TODO https://github.com/opencontainers/image-spec/pull/1172
		}["\(.architecture // "")/\(.variant // "")"]
		// .variant
	)
	| _sort_by_key(sort_split_pref([
		"os",
		"architecture",
		"variant",
		"os.version",
		empty # trailing comma hack
	]))
	| map_values(select(.))
;

# input: *normalized* OCI "platform" object (see link above)
# output: something suitable for use in "sort_by" for sorting things based on platform
def sort_split_platform:
	.["os", "architecture", "variant", "os.version"] //= ""
	| [
		(.os | sort_split_pref([ "linux" ])),
		(.architecture | sort_split_pref([ "amd64", "arm64" ])),
		(.variant | sort_split_natural | sort_split_desc),
		(.["os.version"] | sort_split_natural | sort_split_desc),
		empty # trailing comma hack
	]
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/descriptor.md

def normalize_descriptor:
	if .platform then
		.platform |= normalize_platform
	else . end
	| if has("annotations") then
		.annotations |= _sort_by_key
	else . end
	| _sort_by_key(sort_split_pref([
		"mediaType",
		"artifactType",
		"digest",
		"size",
		"platform",
		"annotations",
		empty # trailing comma hack
	]; [
		"urls",
		"data",
		empty # trailing comma hack
	]))
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md#:~:text=manifests%20array%20of%20objects

# input: list of OCI "descriptor" objects (the "manifests" array of an image index; see link above)
# output: the same list, sorted such that attestation manifests are next to their subject
# https://github.com/moby/buildkit/blob/c6145c2423de48f891862ac02f9b2653864d3c9e/docs/attestations/attestation-storage.md
def sort_attestations:
	[ .[].digest ] as $digs
	| sort_by(
		.digest as $dig
		| .annotations["vnd.docker.reference.digest"] as $subject
		| ($digs | index($subject // $dig) * 2)
		+ if $subject then 1 else 0 end
	)
;
# input: list of OCI "descriptor" objects (the "manifests" array of an image index; see link above)
# output: the same list, sorted appropriately by platform with attestation manifests next to their subject
def sort_manifests:
	sort_by(.platform | sort_split_platform)
	| sort_attestations
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md
# https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md
def normalize_manifest:
	if has("manifests") then
		.manifests[] |= normalize_descriptor
		| .manifests |= sort_manifests
	else . end
	| if has("config") then
		.config |= normalize_descriptor
	else . end
	| if has("layers") then
		.layers[] |= normalize_descriptor
	else . end
	| if has("annotations") then
		.annotations |= _sort_by_key
	else . end
	| _sort_by_key(sort_split_pref([
		"schemaVersion",
		"mediaType",
		"artifactType",
		"manifests", # image index
		"config", "layers", # image manifest
		empty # trailing comma hack
	]; [
		"subject",
		"annotations",
		empty # trailing comma hack
	]))
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/media-types.md
def media_type_oci_index: "application/vnd.oci.image.index.v1+json";
def media_type_oci_image: "application/vnd.oci.image.manifest.v1+json";
def media_type_oci_config: "application/vnd.oci.image.config.v1+json";
def media_type_oci_layer: "application/vnd.oci.image.layer.v1.tar";
def media_type_oci_layer_gzip: media_type_oci_layer + "+gzip";

# https://github.com/distribution/distribution/blob/v3.0.0/docs/content/spec/manifest-v2-2.md#media-types
def media_type_dockerv2_list: "application/vnd.docker.distribution.manifest.list.v2+json";
def media_type_dockerv2_image: "application/vnd.docker.distribution.manifest.v2+json";
def media_type_dockerv2_config: "application/vnd.docker.container.image.v1+json";
def media_type_dockerv2_layer: "application/vnd.docker.image.rootfs.diff.tar";
def media_type_dockerv2_layer_gzip: media_type_dockerv2_layer + ".gzip";

def media_types_index: media_type_oci_index, media_type_dockerv2_list;
def media_types_image: media_type_oci_image, media_type_dockerv2_image;
def media_types_config: media_type_oci_config, media_type_dockerv2_config;
def media_types_layer: media_type_oci_layer, media_type_oci_layer_gzip, media_type_dockerv2_layer, media_type_dockerv2_layer_gzip;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/descriptor.md#digests
def validate_oci_digest:
	validate(type == "string"; "digest must be a string")
	| (capture("(?x)
		^
			(?<algorithm>
				[a-z0-9]+
				( [+._-] [a-z0-9]+ )*
			)
			[:]
			(?<encoded>
				[a-zA-Z0-9=_-]+
			)
		$
	") // null) as $dig
	| validate(.; $dig; "invalid digest syntax")
	| {
		"sha256": [ 64 ],
		"sha512": [ 128 ],
	} as $lengths
	| validate_IN($dig.algorithm; $lengths | keys[])
	| validate_length($dig.encoded; $lengths[$dig.algorithm][])
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/annotations.md#rules
def validate_oci_annotations_haver:
	if has("annotations") then
		validate(.annotations; type == "object"; "if present, annotations must be an object")
		| validate(.annotations[]; type == "string"; "annotation values must be strings")
	else . end
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/descriptor.md
def validate_oci_descriptor:
	validate_IN(type; "object")

	| validate(.mediaType; type == "string"; "mediaType must be a string")

	| validate(.digest; validate_oci_digest)

	| validate(.size; type == "number"; "size must be numeric")
	| validate(.size; . >= 0; "size must not be negative")
	| validate(.size; . == floor; "size must be whole")
	| validate(.size; . == ceil; "size must be whole")

	# TODO urls?

	| validate_oci_annotations_haver

	| if has("data") then
		validate(.data; type == "string"; "if present, data must be a string")
		# https://datatracker.ietf.org/doc/html/rfc4648#section-4
		| validate(.data; test("^[A-Za-z0-9+/]*=*$"); "data must be valid base64")
		| .size as $size
		| ($size / 3 | ceil * 4) as $dataSize
		| validate(.data; length == $dataSize; "given size of \($size), data should be \($dataSize) characters long (with padding), not \(length)")
		# someday, maybe we can validate that .data matches .digest here (needs more jq functionality, including and especially the ability to deal with non-UTF8 binary data from base64 and perform sha256 over it)
	else . end

	# TODO artifactType?

	# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md#image-index-property-descriptions
	| if has("platform") then
		validate(.platform;
			validate_IN(type; "object")
			| validate(.architecture; type == "string" and length > 0)
			| validate(.os; type == "string" and length > 0)
			| if has("os.version") then
				validate(."os.version"; type == "string" and length > 0)
			else . end
			| if has("os.features") then
				validate(."os.features"; type == "array")
				| validate(."os.features"[]; type == "string")
			else . end
			| if has("variant") then
				validate(.variant; type == "string" and length > 0)
			else . end
			| if has("features") then
				validate(."features"; type == "array")
				| validate(."features"[]; type == "string")
			else . end
		)
	else . end
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md
# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md
def validate_oci_subject_haver:
	if has("subject") then
		validate(.subject; validate_oci_descriptor)
	else . end
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md
def validate_oci_index:
	validate_IN(type; "object")
	| validate_IN(.schemaVersion; 2)
	| validate_IN(.mediaType; media_types_index) # TODO allow "null" here too? (https://github.com/opencontainers/image-spec/security/advisories/GHSA-77vh-xpmg-72qh)
	# TODO artifactType?
	| validate(.manifests[];
		validate_oci_descriptor
		| validate_IN(.mediaType; media_types_index, media_types_image)
		| validate(.size; . > 2; "manifest size must be at *least* big enough for {} plus *some* content")
		# https://github.com/opencontainers/distribution-spec/pull/293#issuecomment-1452780554
		| validate(.size; . <= 4 * 1024 * 1024; "manifest size must be 4MiB (\(4 * 1024 * 1024)) or less")
	)
	# TODO if any manifest has "vnd.docker.reference.digest", validate the subject exists in the list
	| validate_oci_subject_haver
	| validate_oci_annotations_haver
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md
def validate_oci_image:
	validate_IN(type; "object")
	| validate_IN(.schemaVersion; 2)
	| validate_IN(.mediaType; media_types_image) # TODO allow "null" here too? (https://github.com/opencontainers/image-spec/security/advisories/GHSA-77vh-xpmg-72qh)
	# TODO artifactType (but only selectively / certain values)
	| validate(.config;
		validate_oci_descriptor
		| validate(.size; . >= 2; "config must be at *least* big enough for {}")
		| validate_IN(.mediaType; media_types_config)
	)
	| validate(.layers[];
		validate_oci_descriptor
		| validate_IN(.mediaType; media_types_layer) # TODO allow "application/vnd.in-toto+json" and friends, but selectively 🤔
	)
	| validate_oci_subject_haver
	| validate_oci_annotations_haver
;

# https://github.com/opencontainers/image-spec/blob/v1.1.1/image-layout.md#oci-layout-file
def validate_oci_layout_file:
	validate_IN(.imageLayoutVersion; "1.0.0")
;

# TODO validate digest, size of blobs (*somewhere*, probably not here - this is all "cheap" validations / version+ordering+format assumption validations)
# TODO if .data, validate that somehow too (size, digest); https://github.com/jqlang/jq/issues/1116#issuecomment-2515814615
# TODO also we should validate that the length of every/any manifest is <= 4MiB (https://github.com/opencontainers/distribution-spec/pull/293#issuecomment-1452780554)
