# input: "build" object (with "buildId" top level key)
# output: boolean
def needs_build:
	.build.resolved == null
;
# input: "build" object (with "buildId" top level key)
# output: string ("Builder", but normalized)
def normalized_builder:
	.build.arch as $arch
	| .source.entry.Builder
	| if . == "" then
		if $arch | startswith("windows-") then
			# https://github.com/microsoft/Windows-Containers/issues/34
			"classic"
		else
			"buildkit"
		end
	else . end
;
def docker_uses_containerd_storage:
	# TODO somehow detect docker-with-containerd-storage
	false
;
# input: "build" object (with "buildId" top level key)
# output: boolean
def should_use_docker_buildx_driver:
	normalized_builder == "buildkit"
	and (
		docker_uses_containerd_storage
		or (
			.build.arch as $arch
			# bashbrew remote arches --json tianon/buildkit:0.12 | jq '.arches | keys_unsorted' -c
			| ["amd64","arm32v5","arm32v6","arm32v7","arm64v8","i386","mips64le","ppc64le","riscv64","s390x"]
			# TODO this needs to be based on the *host* architecture, not the *target* architecture (amd64 vs i386)
			| index($arch)
			| not
			# TODO "failed to read dockerfile: failed to load cache key: subdir not supported yet" asdflkjalksdjfklasdjfklajsdklfjasdklgfnlkasdfgbhnkljasdhgouiahsdoifjnask,.dfgnklasdbngoikasdhfoiasjdklfjasdlkfjalksdjfkladshjflikashdbgiohasdfgiohnaskldfjhnlkasdhfnklasdhglkahsdlfkjasdlkfjadsklfjsdl (hence "tianon/buildkit" instead of "moby/buildkit"; need *all* the arches we care about/support for consistent support)
		)
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
# output: string "giturl" ("https://github.com/docker-library/golang.git#commit:directory), used for "docker buildx build giturl"
def git_build_url:
	.source.entry
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
		# https://github.com/opencontainers/image-spec/blob/v1.1.0-rc4/annotations.md#pre-defined-annotation-keys
		"org.opencontainers.image.source": $buildUrl,
		"org.opencontainers.image.revision": .source.entry.GitCommit,
		"org.opencontainers.image.created": (.source.entry.SOURCE_DATE_EPOCH | strftime("%FT%TZ")), # see notes below about image index vs image manifest

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
	| with_entries(select(.value)) # strip off anything missing a value (possibly "source", "url", "version", etc)
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
		| (
			(should_use_docker_buildx_driver | not)
			or docker_uses_containerd_storage
		) as $supportsAnnotationsAndAttestsations
		| [
			(
				[
					@sh "SOURCE_DATE_EPOCH=\(.source.entry.SOURCE_DATE_EPOCH)",
					# TODO EXPERIMENTAL_BUILDKIT_SOURCE_POLICY=<(jq ...)
					"docker buildx build --progress=plain",
					if $supportsAnnotationsAndAttestsations then
						"--provenance=mode=max",
						# see "bashbrew remote arches docker/scout-sbom-indexer:1" (we need the SBOM scanner to be runnable on the host architecture)
						# bashbrew remote arches --json docker/scout-sbom-indexer:1 | jq '.arches | keys_unsorted' -c
						if .build.arch as $arch | ["amd64","arm32v5","arm32v7","arm64v8","i386","ppc64le","riscv64","s390x"] | index($arch) then
							# TODO this needs to be based on the *host* architecture, not the *target* architecture (amd64 vs i386)
							"--sbom=generator=\"$BASHBREW_BUILDKIT_SBOM_GENERATOR\""
							# TODO this should also be totally optional -- for example, Tianon doesn't want SBOMs on his personal images
						else empty end,
						empty
					else empty end,
					"--output " + (
						[
							if should_use_docker_buildx_driver then
								"type=docker"
							else
								"type=oci",
								"dest=temp.tar", # TODO choose/find a good "safe" place to put this (temporarily)
								empty
							end,
							empty
						]
						| @csv
						| @sh
					),
					(
						if $supportsAnnotationsAndAttestsations then
							build_annotations($buildUrl)
							| to_entries
							# separate loops so that "image manifest" annotations are grouped separate from the index/descriptor annotations (easier to read)
							| (
								.[]
								| @sh "--annotation \(.key + "=" + .value)"
							),
							(
								.[]
								| @sh "--annotation \(
									"manifest-descriptor:" + .key + "="
									+ if .key == "org.opencontainers.image.created" then
										# the "current" time breaks reproducibility (for the purposes of build verification), so we put "now" in the image index but "SOURCE_DATE_EPOCH" in the image manifest (which is the thing we'd ideally like to have reproducible, eventually)
										(env.SOURCE_DATE_EPOCH // now) | tonumber | strftime("%FT%TZ")
										# (this assumes the actual build is going to happen shortly after generating the command)
									else .value end
								)",
								empty
							)
						else empty end
					),
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
				] | join(" \\\n\t")
			),
			if should_use_docker_buildx_driver then empty else
				# munge the tarball into a suitable "oci layout" directory (ready for "crane push")
				"mkdir temp",
				"tar -xvf temp.tar -C temp",
				"rm temp.tar",
				# munge the index to what crane wants ("Error: layout contains 5 entries, consider --index")
				@sh "jq \("
					.manifests |= (
						del(.[].annotations)
						| unique
						| if length != 1 then
							error(\"unexpected number of manifests: \" + length)
						else . end
					)
				" | unindent_and_decomment_jq(4)) temp/index.json > temp/index.json.new",
				"mv temp/index.json.new temp/index.json",
				empty
			end,
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
				| join(" \\\n\t")
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
			# "crane push" is easier to get correct than "ctr image import" + "ctr image push", especially with authentication
			@sh "crane push temp \(.build.img)",
			"rm -rf temp",
			empty
		] | join("\n")
	elif $builder == "oci-import" then
		"TODO"
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
		push: push_command,
	}
;
