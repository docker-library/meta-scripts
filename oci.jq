include "sort";

# https://github.com/opencontainers/image-spec/blob/v1.1.0/image-index.md#:~:text=generate%20an%20error.-,platform%20object,-This%20OPTIONAL%20property

# input: OCI "platform" object (see link above)
# output: normalized OCI "platform" object
def normalize_platform:
	.variant = (
		{
			# https://github.com/golang/go/blob/e85968670e35fc24987944c56277d80d7884e9cc/src/cmd/dist/build.go#L145-L185
			# https://github.com/golang/go/blob/e85968670e35fc24987944c56277d80d7884e9cc/src/internal/buildcfg/cfg.go#L58-L175
			# https://github.com/containerd/platforms/blob/db76a43eaea9a004a5f240620f966b0081123884/database.go#L75-L109
			# https://github.com/opencontainers/image-spec/blob/v1.1.0/image-index.md#platform-variants

			#"amd64/": "v1", # TODO https://github.com/opencontainers/image-spec/pull/1172
			"arm/": "v7",
			"arm64/": "v8", # TODO v8.0 ?? https://github.com/golang/go/issues/60905 -> https://go-review.googlesource.com/c/go/+/559555/comment/e2049987_1bc3a065/ (no support for vX.Y in containerd; likely nowhere else either); https://github.com/opencontainers/image-spec/pull/1172
			#"ppc64le/": "power8", # TODO https://github.com/opencontainers/image-spec/pull/1172
			#"riscv64/": "rva20u64", # TODO https://github.com/opencontainers/image-spec/pull/1172
		}["\(.architecture // "")/\(.variant // "")"]
		// .variant
	)
	| to_entries
	| sort_by(.key | sort_split_pref([
		"os",
		"architecture",
		"variant",
		"os.version",
		empty # trailing comma hack
	]))
	| map(select(.value))
	| from_entries
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

# https://github.com/opencontainers/image-spec/blob/v1.1.0/descriptor.md

def normalize_descriptor:
	if .platform then
		.platform |= normalize_platform
	else . end
	| to_entries
	| sort_by(.key | sort_split_pref([
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
	| from_entries
;

# https://github.com/opencontainers/image-spec/blob/v1.1.0/image-index.md#:~:text=manifests%20array%20of%20objects

# input: list of OCI "descriptor" objects (the "manifests" array of an image index; see link above)
# output: the same list, sorted such that attestation manifests are next to their subject
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

# https://github.com/opencontainers/image-spec/blob/v1.1.0/image-index.md

def validate_oci_index_media_type:
	if . != "application/vnd.oci.image.index.v1+json" then
		error("unsupported index mediaType: \(.)")
	else . end
;

def validate_oci_index:
	if .schemaVersion != 2 then
		error("unsupported index schemaVersion: \(.schemaVersion)")
	else . end
	| .mediaType |= if . then # TODO drop this conditional (BuildKit 0.14+): https://github.com/moby/buildkit/issues/4595
		validate_oci_index_media_type
	else . end
;

# https://github.com/opencontainers/image-spec/blob/v1.1.0/image-layout.md#oci-layout-file
def validate_oci_layout_file:
	if .imageLayoutVersion != "1.0.0" then
		error("unsupported imageLayoutVersion: \(.imageLayoutVersion)")
	else . end
;

# https://github.com/opencontainers/image-spec/blob/v1.1.0/image-layout.md#indexjson-file
def validate_oci_layout_index:
	validate_oci_index
	| .manifests |= (
		if length != 1 then
			error("expected only one manifests entry, not \(length)")
		else . end
		| .[0] |= (
			if .size < 0 then
				error("invalid descriptor size: \(.size)")
			else . end
			# TODO validate .digest somehow (`crane validate`?) - would also be good to validate all descriptors recursively
			| .mediaType |= validate_oci_index_media_type
		)
	)
;

# input: array of 'oci-layout' file contents followed by 'index.json' file contents (`jq -s 'validate_oci_layout' dir/oci-layout dir/index.json`)
def validate_oci_layout:
	if length != 2 then
		error("unexpected input: expecting single-document 'oci-layout' and 'index.json'")
	else . end
	| .[0] |= validate_oci_layout_file
	| .[1] |= validate_oci_layout_index
;
