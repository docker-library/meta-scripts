# "build_should_sbom", etc.
include "doi";

# input: "build" object (with "buildId" top level key)
# output: boolean
def needs_build:
	.build.resolved == null
;
# input: "build" object (with "buildId" top level key)
# output: string ("Builder", but normalized)
def normalized_builder:
	.build.arch as $arch
	| .source.entries[0].Builder
	| if . == "" then
		if $arch | startswith("windows-") then
			# https://github.com/microsoft/Windows-Containers/issues/34
			"classic"
		else
			"buildkit"
		end
	else . end
;
# input: "docker.io/library/foo:bar"
# output: "foo:bar"
def normalize_ref_to_docker:
	ltrimstr("docker.io/")
	| ltrimstr("library/")
;
# input: "build" object (with "buildId" top level key)
# output: string "pull command" ("docker pull ..."), may be multiple lines, expects to run in Bash with "set -Eeuo pipefail", might be empty
def pull_command:
	normalized_builder as $builder
	| if $builder == "classic" then
		[
			(
				.build.resolvedParents
				| to_entries[]
				| (
					.value.manifests[0].annotations["org.opencontainers.image.ref.name"]
					// .value.annotations["org.opencontainers.image.ref.name"]
					// error("parent \(.key) missing ref")
					| normalize_ref_to_docker
				) as $ref
				| @sh "docker pull \($ref)",
					@sh "docker tag \($ref) \(.key)"
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
# output: string "giturl" ("https://github.com/docker-library/golang.git#commit:directory), used for "docker buildx build giturl"
def git_build_url:
	.source.entries[0]
	| (
		.GitRepo
		| if (endswith(".git") | not) then
			if test("^https?://github.com/") then
				# without ".git" in the url "docker buildx build url" fails and tries to build the html repo page as a Dockerfile
				# https://github.com/moby/buildkit/blob/0e1e36ba9eb8142968b2c5cfa2f12549bf9246d9/util/gitutil/git_ref.go#L81-L87
				# https://github.com/docker/cli/issues/1738
				. + ".git"
			else
				error("\(.) does not end in '.git' so build will fail to recognize it as a Git URL")
			end
		else . end
	) + "#" + .GitCommit + ":" + .Directory
;
# input: "build" object (with "buildId" top level key)
# output: map of annotations to set
def build_annotations($buildUrl):
	{
		# https://github.com/opencontainers/image-spec/blob/v1.1.0/annotations.md#pre-defined-annotation-keys
		"org.opencontainers.image.source": $buildUrl,
		"org.opencontainers.image.revision": .source.entries[0].GitCommit,
		"org.opencontainers.image.created": (
			if .source.entries[0].Builder == "oci-import" then
				.source.entries[0].SOURCE_DATE_EPOCH
			else
				env.SOURCE_DATE_EPOCH // now
				| tonumber
			end
			| strftime("%FT%TZ")
		),

		# TODO come up with less assuming values here? (Docker Hub assumption, tag ordering assumption)
		"org.opencontainers.image.version": ( # value of the first image tag
			first(.source.arches[.build.arch].tags[] | select(contains(":")))
			| sub("^.*:"; "")
			# TODO maybe we should do the first, longest, non-latest tag instead of just the first tag?
		),
		"org.opencontainers.image.url": ( # URL to Docker Hub
			first(.source.arches[.build.arch].tags[] | select(contains(":")))
			| sub(":.*$"; "")
			| if contains("/") then
				"r/" + .
			else
				"_/" + .
			end
			| "https://hub.docker.com/" + .
		),

		# TODO org.opencontainers.image.vendor ? (feels leaky to put "Docker Official Images" here when this is all otherwise mostly generic)

		"com.docker.official-images.bashbrew.arch": .build.arch,
	}
	+ (
		.source.arches[.build.arch].lastStageFrom as $lastStageFrom
		| if $lastStageFrom then
			.build.parents[$lastStageFrom] as $lastStageDigest
			| {
				"org.opencontainers.image.base.name": $lastStageFrom,
			}
			+ if $lastStageDigest then
				{
					"org.opencontainers.image.base.digest": .build.parents[$lastStageFrom],
				}
			else {} end
		else {} end
	)
	| with_entries(select(.value)) # strip off anything missing a value (possibly "source", "url", "version", "base.digest", etc)
;
def build_annotations:
	build_annotations(git_build_url)
;
# input: multi-line string with indentation and comments
# output: multi-line string with less indentation and no comments
def unindent_and_decomment_jq($indents):
	# trim out comment lines and unnecessary indentation
	gsub("(?m)^(\t+#[^\n]*\n?|\t{\($indents)}(?<extra>.*)$)"; "\(.extra // "")")
	# trim out empty lines
	| gsub("\n\n+"; "\n")
;
# input: "build" object (with "buildId" top level key)
# output: string "build command" ("docker buildx build ..."), may be multiple lines, expects to run in Bash with "set -Eeuo pipefail"
def build_command:
	normalized_builder as $builder
	| if $builder == "buildkit" then
		git_build_url as $buildUrl
		| [
			(
				[
					# TODO EXPERIMENTAL_BUILDKIT_SOURCE_POLICY=<(jq ...)
					"docker buildx build --progress=plain",
					@sh "--provenance=mode=max,builder-id=\(buildkit_provenance_builder_id)",
					if build_should_sbom then
						"--sbom=generator=\"$BASHBREW_BUILDKIT_SBOM_GENERATOR\""
					else empty end,
					"--output " + (
						[
							"type=oci",
							"dest=temp.tar",
							empty
						]
						| @csv
						| @sh
					),
					(
						build_annotations($buildUrl)
						| to_entries[]
						| @sh "--annotation \("manifest,manifest-descriptor:\(.key + "=" + .value)")"
					),
					(
						(
							.source.arches[.build.arch]
							| .tags[], .archTags[]
						),
						.build.img
						| "--tag " + @sh
					),
					@sh "--platform \(.source.arches[.build.arch].platformString)",
					(
						.build.resolvedParents
						| to_entries[]
						| .key + "=docker-image://" + (
							.value.manifests[0].annotations["org.opencontainers.image.ref.name"]
							// .value.annotations["org.opencontainers.image.ref.name"]
							// error("parent \(.key) missing ref")
							| normalize_ref_to_docker
						)
						| "--build-context " + @sh
					),
					"--build-arg BUILDKIT_SYNTAX=\"$BASHBREW_BUILDKIT_SYNTAX\"", # TODO .doi/.bin/bashbrew-buildkit-env-setup.sh
					"--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=all", # disable linting (https://github.com/moby/buildkit/pull/4962)
					@sh "--file \(.source.entries[0].File)",
					($buildUrl | @sh),
					empty
				] | join(" \\\n\t")
			),
			# munge the tarball into a suitable "oci layout" directory (ready for "crane push")
			"mkdir temp",
			"tar -xvf temp.tar -C temp",
			"rm temp.tar",
			# TODO munge the image config here to remove any label that doesn't have a "." in the name (https://github.com/docker-library/official-images/pull/18692#issuecomment-2797149554; "thanks UBI/OpenShift/RedHat!")
			# munge the index to what crane wants ("Error: layout contains 5 entries, consider --index")
			@sh "jq \("
				.manifests |= (
					unique_by([ .digest, .size, .mediaType ])
					| if length != 1 then
						error(\"unexpected number of manifests: \\(length)\")
					else . end
				)
			" | unindent_and_decomment_jq(3)) temp/index.json > temp/index.json.new",
			"mv temp/index.json.new temp/index.json",
			# possible improvements in buildkit/buildx that could help us:
			# - allowing OCI output directly to a directory instead of a tar (thus getting symmetry with the oci-layout:// inputs it can take)
			# - allowing tag as one thing and push as something else, potentially mutually exclusive
			# - allowing annotations that are set for both "manifest" and "manifest-descriptor" simultaneously
			# - direct-to-containerd image storage
			empty
		] | join("\n")
	elif $builder == "classic" then
		git_build_url as $buildUrl
		| [
			(
				[
					"DOCKER_BUILDKIT=0",
					"docker build",
					(
						(
							.source.arches[.build.arch]
							| .tags[], .archTags[]
						),
						.build.img
						| "--tag " + @sh
					),
					@sh "--platform \(.source.arches[.build.arch].platformString)",
					@sh "--file \(.source.entries[0].File)",
					($buildUrl | @sh),
					empty
				]
				| join(" \\\n\t")
			),
			empty
		] | join("\n")
	elif $builder == "oci-import" then
		[
			@sh "build=\(tojson)",
			"\"$BASHBREW_META_SCRIPTS/helpers/oci-import.sh\" <<<\"$build\" temp",

			if build_should_sbom then
				"# SBOM",
				"mv temp temp.orig",
				"\"$BASHBREW_META_SCRIPTS/helpers/oci-sbom.sh\" <<<\"$build\" temp.orig temp",
				"rm -rf temp.orig",
				empty
			else empty end
		] | join("\n")
	else
		error("unknown/unimplemented Builder: \($builder)")
	end
;

# input: "build" object (with "buildId" top level key)
def image_digest:
	.build.resolved.manifests[0].digest
;

# input: "build" object (with "buildId" top level key)
def image_ref:
	"\(.build.img)@\(image_digest)"
;

# input: "build" object (with "buildId" top level key)
# output: string "command for generating an SBOM from an OCI layout", may be multiple lines, expects to run in Bash with "set -Eeuo pipefail"
def sbom_command:
	[
		"build_output=$(",
		(
			[
				"\tdocker buildx build --progress=rawjson",
				"--provenance=false",
				"--sbom=generator=\"$BASHBREW_BUILDKIT_SBOM_GENERATOR\"",
				(
					(
						.source.arches[.build.arch]
						| .tags[], .archTags[]
					),
					.build.img
					| "--tag " + @sh
				),
				"--output " + (
					[
						"type=oci",
						"tar=false",
						"dest=sbom",
						empty
					]
					| @csv
					| @sh
				),
				"- <<<" + (
					[
						"FROM ",
						image_ref,
						empty
					]
					| join("")
					| @sh
				) + " 2>&1",
				empty
			] | join(" \\\n\t")
		),
		")",
		# Using the method above assigns the wrong image digest in the SBOM subjects. This replaces it with the correct one
		# Get the digest of the attestation manifest provided by BuildKit
		"attest_manifest_digest=$(",
		(
			[
				"\techo \"$build_output\" | jq -rs '",
				(
					[
						"\t.[]",
						"| select(.statuses).statuses[]",
						"| select((.completed != null) and (.id | startswith(\"exporting attestation manifest\"))).id",
						"| sub(\"exporting attestation manifest \"; \"\")",
						empty
					] | join("\n\t\t")
				),
				"'",
				empty
			] | join("\n\t")
		),
		")",
		# Find the SBOM digest from the attestation manifest
		"sbom_digest=$(",
		(
			[
				"\tjq -r '",
				(
					[
						"\t.layers[] | select(.annotations[\"in-toto.io/predicate-type\"] == \"https://spdx.dev/Document\").digest",
						empty
					] | join("\n\t\t")
				),
				"' \"sbom/blobs/${attest_manifest_digest//://}\"",
				empty
			] | join("\n\t")
		),
		")",
		# Replace the subjects digests
		"jq -c --arg digest \"\(image_digest)\" '",
		(
			[
				"\t.subject[].digest |= ($digest | split(\":\") | {(.[0]): .[1]})",
				empty
			] | join("\n\t")
		),
		"' \"sbom/blobs/${sbom_digest//://}\" > sbom.json",
		empty
	] | join("\n")
;

# input: "build" object (with "buildId" top level key)
# output: string "push command" ("docker push ..."), may be multiple lines, expects to run in Bash with "set -Eeuo pipefail"
def push_command:
	normalized_builder as $builder
	| if $builder == "classic" then
		@sh "docker push \(.build.img)"
	elif IN($builder; "buildkit", "oci-import") then
		[
			@sh "crane push temp \(.build.img)",
			"rm -rf temp",
			empty
		] | join("\n")
	else
		error("unknown/unimplemented Builder: \($builder)")
	end
;
# input: "build" object (with "buildId" top level key)
# output: "commands" object with keys "pull", "build", "push"
def commands:
	{
		pull: pull_command,
		build: build_command,
		sbom_scan: sbom_command,
		push: push_command,
	}
;
