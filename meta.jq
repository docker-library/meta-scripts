# input: "build" object (with "buildId" top level key)
# output: boolean
def needs_build:
	.build.resolved == null
;
# input "build" object (with "buildId" top level key)
# output: string ("Builder", but normalized)
def normalized_builder:
	.source.entry.Builder
	| if . == "" then "buildkit" else . end
;
# input "build" object (with "buildId" top level key)
# output: boolean
def should_use_docker_buildx_driver:
	normalized_builder == "buildkit"
	and (
		.build.arch as $arch
		# TODO .doi/.bin/bashbrew-buildkit-env-setup.sh (needs to be set appropriately per-architecture, and this arch list needs to match that one)
		| [ "amd64", "arm64v8" ]
		# see "bashbrew remote arches moby/buildkit:buildx-stable-1" (we need buildkit-in-docker for --provenance today)
		# see "bashbrew remote arches docker/buildkit-syft-scanner:stable-1" (we need the SBOM scanner to be runnable on the host architecture)
		# currently these are controlled by the same arch list because they overlap but we could split them (or rely on "bashbrew-buildkit-env-setup.sh" to set variables correctly where they can be used, but that's a little more complicated esp since we can't use "type=oci" with the "docker" driver 🙈), but we can't SBOM without buildkit-in-docker (yet? containerd integration in Docker?)
		| index($arch)
		| not
	)
;
# input: "build" object (with "buildId" top level key)
# output: string "pull command" ("docker pull ..."), may be multiple lines, expects to run in Bash with "set -Eeuo pipefail", might be empty
def pull_command:
	normalized_builder as $builder
	| if $builder == "classic" or should_use_docker_buildx_driver then
		[
			(
				.build.resolvedParents | to_entries[] |
				@sh "docker pull \(.value.manifest.ref)",
				@sh "docker tag \(.value.manifest.ref) \(.key)"
			),
			empty
		] | join("\n")
	elif $builder == "buildkit" then
		"" # buildkit has to pull during build 🙈
	elif $builder == "oci-import" then
		"" # "oci-import" is essentially "FROM scratch"
	else
		error("unknown/unimplemented Builder: \($builder)")
	end
;
# input: "build" object (with "buildId" top level key)
# output: string "build command" ("docker buildx build ..."), may be multiple lines, expects to run in Bash with "set -Eeuo pipefail"
def build_command:
	normalized_builder as $builder
	| (.source.entry.GitRepo + "#" + .source.entry.GitCommit + ":" + .source.entry.Directory) as $buildUrl
	| if $builder == "buildkit" then
		[
			(
				[
					@sh "SOURCE_DATE_EPOCH=\(.source.entry.SOURCE_DATE_EPOCH)",
					# TODO EXPERIMENTAL_BUILDKIT_SOURCE_POLICY=<(jq ...)
					"docker buildx build --progress=plain",
					if should_use_docker_buildx_driver then "--load" else # TODO if we get containerd integration and thus use "--load" unconditionally again, we should update this to still set annotations! (and still gate SBOMs on appropriate scanner-supported architectures)
						"--provenance=mode=max",
						"--sbom=generator=\"$BASHBREW_BUILDKIT_SBOM_GENERATOR\"",
						(
							"--output " + (
								[
									"type=oci", # TODO find a better way to build/tag with a full list of tags but only actually *push* to one of them so we don't have to round-trip through containerd
									"dest=temp.tar", # TODO choose/find a good "safe" place to put this (temporarily)
									(
										{
											# https://github.com/opencontainers/image-spec/blob/v1.1.0-rc4/annotations.md#pre-defined-annotation-keys
											"org.opencontainers.image.source": $buildUrl,
											"org.opencontainers.image.revision": .source.entry.GitCommit,

											# TODO come up with less assuming values here? (Docker Hub assumption, tag ordering assumption)
											"org.opencontainers.image.version": ( # value of the first image tag
												first(.source.allTags[] | select(contains(":")))
												| sub("^.*:"; "")
												# TODO maybe we should do the first, longest, non-latest tag instead of just the first tag?
											),
											"org.opencontainers.image.url": ( # URL to Docker Hub
												first(.source.allTags[] | select(contains(":")))
												| sub(":.*$"; "")
												| if contains("/") then
													"r/" + .
												else
													"_/" + .
												end
												| "https://hub.docker.com/" + .
											),
											# TODO org.opencontainers.image.vendor ? (feels leaky to put "Docker Official Images" here when this is all otherwise mostly generic)
										}
										| to_entries[] | select(.value != null) |
										"annotation." + .key + "=" + .value,
										"annotation-manifest-descriptor." + .key + "=" + .value
									),
									empty
								]
								| @csv
								| @sh
							)
						),
						empty
					end,
					(
						.source.arches[].tags[],
						.source.arches[].archTags[],
						.build.img
						| "--tag " + @sh
					),
					@sh "--platform \(first(.source.arches[].platformString))",
					(
						.build.resolvedParents
						| to_entries[]
						| .key + "=docker-image://" + .value.manifest.ref
						| "--build-context " + @sh
					),
					"--build-arg BUILDKIT_SYNTAX=\"$BASHBREW_BUILDKIT_SYNTAX\"", # TODO .doi/.bin/bashbrew-buildkit-env-setup.sh
					@sh "--file \(.source.entry.File)",
					($buildUrl | @sh),
					empty
				] | join(" ")
			),
			# possible improvements in buildkit/buildx that could help us:
			# - allowing OCI output directly to a directory instead of a tar (thus getting symmetry with the oci-layout:// inputs it can take)
			# - allowing tag as one thing and push as something else, potentially mutually exclusive
			# - allowing annotations that are set for both "manifest" and "manifest-descriptor" simultaneously
			# - direct-to-containerd image storage
			empty
		] | join("\n")
	elif $builder == "classic" then
		[
			(
				[
					@sh "SOURCE_DATE_EPOCH=\(.source.entry.SOURCE_DATE_EPOCH)",
					"DOCKER_BUILDKIT=0",
					"docker build",
					(
						.source.arches[].tags[],
						.source.arches[].archTags[],
						.build.img
						| "--tag " + @sh
					),
					@sh "--platform \(first(.source.arches[].platformString))",
					@sh "--file \(.source.entry.File)",
					($buildUrl | @sh),
					empty
				]
				| join(" ")
			),
			empty
		] | join("\n")
	elif $builder == "oci-import" then
		[
			"git init temp", # TODO figure out a good, safe place to temporary "git init"??
			@sh "git -C temp fetch \(.source.entry.GitRepo) \(.source.entry.GitCommit): || git -C temp fetch \(.source.entry.GitRepo) \(.source.entry.GitFetch):",
			@sh "git -C temp checkout -q \(.source.entry.GitCommit)",
			# TODO something clever, especially to deal with "index.json" vs not-"index.json" (possibly using "jq" to either synthesize/normalize to what we actually need it to be for "crane push temp/dir \(.build.img)")
			empty
		] | join("\n")
	else
		error("unknown/unimplemented Builder: \($builder)")
	end
;
# input: "build" object (with "buildId" top level key)
# output: string "push command" ("docker push ..."), may be multiple lines, expects to run in Bash with "set -Eeuo pipefail"
def push_command:
	normalized_builder as $builder
	| if $builder == "classic" or should_use_docker_buildx_driver then
		@sh "docker push \(.build.img)"
	elif $builder == "buildkit" then
		[
			# extract to a directory and "crane push" (easier to get correct than "ctr image import" + "ctr image push", especially with authentication)
			"mkdir temp",
			"tar -xvf temp.tar -C temp",
			# munge the index to what crane wants ("Error: layout contains 5 entries, consider --index")
			@sh "jq \(".manifests |= (del(.[].annotations) | unique)") temp/index.json > temp/index.json.new",
			"mv temp/index.json.new temp/index.json",
			@sh "crane push temp \(.build.img)",
			"rm -rf temp temp.tar",
			empty
		] | join("\n")
	elif $builder == "oci-import" then
		"TODO"
	else
		error("unknown/unimplemented Builder: \($builder)")
	end
;
