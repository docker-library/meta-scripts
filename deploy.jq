include "oci";

# input: array of "build" objects (with "buildId" top level keys)
# output: map of { "tag": [ list of OCI descriptors ], ... }
def tagged_manifests(builds_selector; tags_extractor):
	reduce (.[] | select(.build.resolved and builds_selector)) as $i ({};
		.[
			$i
			| tags_extractor
			| ..|strings # no matter what "tags_extractor" gives us, this will flatten us to a stream of strings
		] += $i.build.resolved.manifests
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
							if $manifests[0]?.mediaType == "application/vnd.docker.distribution.manifest.v2+json" then
								"application/vnd.docker.distribution.manifest.list.v2+json"
							else
								"application/vnd.oci.image.index.v1+json"
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
