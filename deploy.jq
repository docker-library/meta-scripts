include "oci";

# input: array of "build" objects (with "buildId" top level keys)
# output: map of { "tag": [ list of OCI descriptors ], ... }
def tagged_manifests(builds_selector; tags_extractor):
	reduce (.[] | select(.build.resolved and builds_selector)) as $i ({};
		.[
			$i
			| tags_extractor
			| ..|strings # no matter what "tags_extractor" gives us, this will flatten us to a stream of strings
		] += [
			# as an extra protection against cross-architecture "bleeding" ("riscv64" infra pushing "amd64" images, for example), filter the list of manifests to those whose architecture matches the architecture it is supposed to be for
			# to be explicitly clear, this filtering is *also* done as part of our "builds.json" generation, so this is an added layer of best-effort protection that will be especially important to preserve and/or replicate if/when we solve the "not built yet so include the previous contents of the tag" portion of the problem at this layer instead of in the currently-separate put-shared process
			$i.build.resolved.manifests[]
			| select(.annotations["com.docker.official-images.bashbrew.arch"] // "" == $i.build.arch) # this assumes "registry.SynthesizeIndex" created this list of manifests (because it sets this annotation), but it would be reasonable for us to reimplement that conversion of "OCI platform object" to "bashbrew architecture" in pure jq if it was prudent or necessary to do so
		]
	)
;
def arch_tagged_manifests($arch):
	tagged_manifests(.build.arch == $arch; .source.arches[.build.arch].archTags)
;

# input: output of tagged_manifests (map of tag -> list of OCI descriptors)
# output: array of input objects for "cmd/deploy" ({ "type": "manifest", "refs": [ ... ], "data": { ... } })
def deploy_objects:
	reduce to_entries[] as $in ({};
		$in.key as $ref
		| (
			$in.value
			| map(normalize_descriptor) # normalized platforms *and* normalized field ordering
			| sort_manifests
		) as $manifests
		| ([ $manifests[].digest ] | join("\n")) as $key
		| .[$key] |= (
			if . then
				.refs += [ $ref ]
			else
				{
					type: "manifest",
					refs: [ $ref ],

					# add appropriate "lookup" values for copying child objects properly
					lookup: (
						$manifests
						| map({
							key: .digest,
							value: (
								.digest as $dig
								| .annotations["org.opencontainers.image.ref.name"]
								| rtrimstr("@" + $dig)
							),
						})
						| from_entries
					),

					# convert the list of "manifests" into a full (canonical!) index/manifest list for deploying
					data: {
						schemaVersion: 2,
						mediaType: (
							if $manifests[0].mediaType == media_type_dockerv2_image then
								media_type_dockerv2_list
							else
								media_type_oci_index
							end
						),
						manifests: (
							$manifests
							| del(.[].annotations["org.opencontainers.image.ref.name"])
						),
					},
				}
			end
		)
	)
	| [ .[] ] # strip off our synthetic map keys to avoid leaking our implementation detail
;
