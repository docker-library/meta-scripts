# fully synthetic input for "deploy.jq" arch filtering (so nothing here depends on real images, registries, or "builds.json" content)

# obviously fake digests: "a" => sha256:aaaa...
def digest($c): "sha256:" + ($c * 64);

# $annotation is the value of the bashbrew arch annotation (null means no annotation at all)
def manifest($c; $arch; $annotation):
	{
		mediaType: "application/vnd.oci.image.manifest.v1+json",
		digest: digest($c),
		size: 1,
		annotations: (
			if $annotation == null then {} else {
				"com.docker.official-images.bashbrew.arch": $annotation,
			} end
		),
		platform: { os: "linux", architecture: $arch },
	}
;

# both builds share the "synthetic:latest" tag (like "library/" tags are shared by every architecture) and have their own arch-specific tag
def build($arch; $manifests):
	{
		buildId: "synthetic-\($arch)",
		build: {
			$arch,
			resolved: {
				schemaVersion: 2,
				manifests: $manifests,
			},
		},
		source: {
			arches: {
				($arch): {
					tags: [ "synthetic:latest" ],
					archTags: [ "synthetic:\($arch)" ],
				},
			},
		},
	}
;

[
	build("amd64"; [
		manifest("a"; "amd64"; "amd64"), # correct arch: KEEP
		manifest("b"; "arm64"; "arm64v8"), # annotated for a different arch (cross-architecture "bleeding"): DROP
		manifest("c"; "amd64"; ""), # empty (but present) annotation, which is truthy in jq: DROP
		manifest("d"; "amd64"; null), # no annotation at all: DROP
		empty # trailing comma
	]),
	build("arm64v8"; [
		manifest("e"; "arm64"; "arm64v8"), # correct arch: KEEP
		manifest("f"; "amd64"; "amd64"), # the same bleeding in the other direction: DROP
		empty # trailing comma
	]),
	empty # trailing comma
]
| map({ (.buildId): . })
| add
