include "oci";

[
	{
		os: "linux",
		architecture: (
			"386",
			"amd64",
			"arm",
			"arm64",
			"mips64le",
			"ppc64le",
			"riscv64",
			"s390x",
			empty
		),
	},

	{
		os: "windows",
		architecture: ( "amd64", "arm64" ),
		"os.version": (
			# https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/base-image-lifecycle
			# https://oci.dag.dev/?repo=mcr.microsoft.com/windows/servercore
			# https://oci.dag.dev/?image=hell/win:core
			"10.0.14393.6796",
			"10.0.16299.1087",
			"10.0.17134.1305",
			"10.0.17763.5576",
			"10.0.18362.1256",
			"10.0.18363.1556",
			"10.0.19041.1415",
			"10.0.19042.1889",
			"10.0.20348.2340",
			empty
		)
	},

	{
		os: "freebsd",
		architecture: ( "amd64", "arm64" ),
		"os.version": ( "12.1", "13.1" ),
	},

	# buildkit attestations
	# https://github.com/moby/buildkit/blob/5e0fe2793d529209ad52e811129f644d972ea094/docs/attestations/attestation-storage.md#attestation-manifest-descriptor
	{
		architecture: "unknown",
		os: "unknown",
	},

	empty
]

# explode out variant matricies
| map(
	{
		# https://github.com/opencontainers/image-spec/pull/1172
		amd64:   [ "v1", "v2", "v3", "v4" ],
		arm64:   [ "v8", "v9", "v8.0", "v9.0", "v8.1", "v9.5" ],
		arm:     [ "v5", "v6", "v7", "v8" ],
		riscv64: [ "rva20u64", "rva22u64" ],
		ppc64le: [ "power8", "power9", "power10" ],
	}[.architecture] as $variants
	| ., if $variants then
		. + { variant: $variants[] }
	else empty end
)

| map(normalize_platform)
| unique
| sort_by(sort_split_platform)
