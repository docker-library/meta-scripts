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
		# https://github.com/opencontainers/image-spec/blob/v1.1.0/annotations.md#pre-defined-annotation-keys
		"org.opencontainers.image.source": $buildUrl,
		"org.opencontainers.image.revision": .source.entry.GitCommit,
		"org.opencontainers.image.created": (.source.entry.SOURCE_DATE_EPOCH | strftime("%FT%TZ")), # see notes below about image index vs image manifest

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
					@sh "SOURCE_DATE_EPOCH=\(.source.entry.SOURCE_DATE_EPOCH)",
					# TODO EXPERIMENTAL_BUILDKIT_SOURCE_POLICY=<(jq ...)
					"docker buildx build --progress=plain",
					@sh "--provenance=mode=max,builder-id=\(buildkit_provenance_builder_id)",
					if build_should_sbom then
						"--sbom=generator=\"$BASHBREW_BUILDKIT_SBOM_GENERATOR\""
					else empty end,
					"--output " + (
						[
							"type=oci",
							"dest=temp.tar", # TODO choose/find a good "safe" place to put this (temporarily)
							"rewrite-timestamp=true",
							empty
						]
						| @csv
						| @sh
					),
					(
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
					@sh "--file \(.source.entry.File)",
					($buildUrl | @sh),
					empty
				] | join(" \\\n\t")
			),
			# munge the tarball into a suitable "oci layout" directory (ready for "crane push")
			"mkdir temp",
			"tar -xvf temp.tar -C temp",
			"rm temp.tar",
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
					@sh "SOURCE_DATE_EPOCH=\(.source.entry.SOURCE_DATE_EPOCH)",
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
			# initialize "~/.cache/bashbrew/git"
			#"gitCache=\"$(bashbrew cat --format '{{ gitCache }}' <(echo 'Maintainers: empty hack (@example)'))\"",
			# https://github.com/docker-library/bashbrew/blob/5152c0df682515cbe7ac62b68bcea4278856429f/cmd/bashbrew/git.go#L52-L80
			"export BASHBREW_CACHE=\"${BASHBREW_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/bashbrew}\"",
			"gitCache=\"$BASHBREW_CACHE/git\"",
			"git init --bare \"$gitCache\"",
			"_git() { git -C \"$gitCache\" \"$@\"; }",
			"_git config gc.auto 0",
			# "bashbrew fetch" but in Bash (because we have bashbrew, but not the library file -- we could synthesize a library file instead, but six of one half a dozen of another)
			@sh "_commit() { _git rev-parse \(.source.entry.GitCommit + "^{commit}"); }",
			@sh "if ! _commit &> /dev/null; then _git fetch \(.source.entry.GitRepo) \(.source.entry.GitCommit + ":") || _git fetch \(.source.entry.GitFetch + ":"); fi",
			"_commit",

			# TODO figure out a good, safe place to store our temporary build/push directory (maybe this is fine? we do it for buildx build too)
			"mkdir temp",
			# https://github.com/docker-library/bashbrew/blob/5152c0df682515cbe7ac62b68bcea4278856429f/cmd/bashbrew/git.go#L140-L147 (TODO "bashbrew context" ?)
			@sh "_git archive --format=tar \(.source.entry.GitCommit + ":" + (.source.entry.Directory | if . == "." then "" else . + "/" end)) | tar -xvC temp",

			# validate oci-layout file (https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L104-L112)
			@sh "jq -s \("
				if length != 1 then
					error(\"unexpected 'oci-layout' document count: \" + length)
				else .[0] end
				| if .imageLayoutVersion != \"1.0.0\" then
					error(\"unsupported imageLayoutVersion: \" + .imageLayoutVersion)
				else . end
			" | unindent_and_decomment_jq(3)) temp/oci-layout > /dev/null",

			# https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L116
			if .source.entry.File != "index.json" then
				@sh "jq -s \("{ schemaVersion: 2, manifests: . }") \("./" + .source.entry.File) > temp/index.json"
			else empty end,

			@sh "jq -s \("
				if length != 1 then
					error(\"unexpected 'index.json' document count: \" + length)
				else .[0] end

				# https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L117-L127
				| if .schemaVersion != 2 then
					error(\"unsupported schemaVersion: \" + .schemaVersion)
				else . end
				# TODO check .mediaType ? (technically optional, but does not have to be *and* shouldn't be); https://github.com/moby/buildkit/issues/4595
				| if .manifests | length != 1 then
					error(\"expected only one manifests entry, not \" + (.manifests | length))
				else . end

				| .manifests[0] |= (
					# https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L135-L144
					if .mediaType != \"application/vnd.oci.image.manifest.v1+json\" then
						error(\"unsupported descriptor mediaType: \" + .mediaType)
					else . end
					# TODO validate .digest somehow (`crane validate`? see below) - would also be good to validate all descriptors recursively (not sure if `crane push` does that)
					| if .size < 0 then
						error(\"invalid descriptor size: \" + .size)
					else . end

					# purge maintainer-provided URLs / annotations (https://github.com/docker-library/bashbrew/blob/4e0ea8d8aba49d54daf22bd8415fabba65dc83ee/cmd/bashbrew/oci-builder.go#L146-L147)
					| del(.annotations, .urls)

					# inject our annotations
					| .annotations = \(build_annotations(.source.entry.GitRepo) | @json)
				)
			" | unindent_and_decomment_jq(3)) temp/index.json > temp/index.json.new",
			"mv temp/index.json.new temp/index.json",

			# TODO consider / check what "crane validate" does and if it would be appropriate here

			if build_should_sbom then
				# we'll trick BuildKit into generating an SBOM for us, then inject it into our OCI layout
				"# SBOM",
				"originalImageManifest=\"$(jq -r '.manifests[0].digest' temp/index.json)\"",
				(
					[
						@sh "SOURCE_DATE_EPOCH=\(.source.entry.SOURCE_DATE_EPOCH)",
						"docker buildx build --progress=plain",
						"--load=false", "--provenance=false", # explicitly disable a few features we want to avoid
						"--build-arg BUILDKIT_DOCKERFILE_CHECK=skip=all", # disable linting (https://github.com/moby/buildkit/pull/4962)
						"--sbom=generator=\"$BASHBREW_BUILDKIT_SBOM_GENERATOR\"",
						"--output 'type=oci,tar=false,dest=sbom,rewrite-timestamp=true'",
						# TODO also add appropriate "--tag" lines (which would give us a mostly correct "subject" block in the generated SBOM, but we'd then need to replace instances of ${sbomImageManifest#*:} with ${originalImageManifest#*:} for their values to be correct)
						@sh "--platform \(.source.arches[.build.arch].platformString)",
						"--build-context \"fake=oci-layout://$PWD/temp@$originalImageManifest\"",
						"- <<<'FROM fake'", # note: "<<<" is a bashism (so this output must be invoked via bash)
						empty
					] | join(" \\\n\t")
				),
				"sbomIndex=\"$(jq -r '.manifests[0].digest' sbom/index.json)\"",
				@sh "shell=\"$(jq -r --arg originalImageManifest \"$originalImageManifest\" \("
					# https://docs.docker.com/build/attestations/attestation-storage/
					first(
						.manifests[]
						| select(.annotations[\"vnd.docker.reference.type\"] == \"attestation-manifest\")
					) as $attDesc
					| @sh \"sbomManifest=\\($attDesc.digest)\",
						@sh \"sbomManifestDesc=\\(
							$attDesc
							| .annotations[\"vnd.docker.reference.digest\"] = $originalImageManifest
							| tojson
						)\"
				" | unindent_and_decomment_jq(4)) \"sbom/blobs/${sbomIndex/://}\")\"",
				"eval \"$shell\"",
				@sh "shell=\"$(jq -r \("
					\"copyBlobs=( \\([ .config.digest, .layers[].digest | @sh ] | join(\" \")) )\"
				" | unindent_and_decomment_jq(4)) \"sbom/blobs/${sbomManifest/://}\")\"",
				"eval \"$shell\"",
				"copyBlobs+=( \"$sbomManifest\" )",
				"for blob in \"${copyBlobs[@]}\"; do",
				"\tcp \"sbom/blobs/${blob/://}\" \"temp/blobs/${blob/://}\"",
				"done",
				"jq -r --argjson sbomManifestDesc \"$sbomManifestDesc\" '.manifests += [ $sbomManifestDesc ]' temp/index.json > temp/index.json.new",
				"mv temp/index.json.new temp/index.json",
				empty
			else empty end
		] | join("\n")
	else
		error("unknown/unimplemented Builder: \($builder)")
	end
;
# input: "build" object (with "buildId" top level key)
# output: string "push command" ("docker push ..."), may be multiple lines, expects to run in Bash with "set -Eeuo pipefail"
def push_command:
	normalized_builder as $builder
	| if $builder == "classic" then
		@sh "docker push \(.build.img)"
	elif $builder == "buildkit" then
		[
			# "crane push" is easier to get correct than "ctr image import" + "ctr image push", especially with authentication
			@sh "crane push temp \(.build.img)",
			"rm -rf temp",
			empty
		] | join("\n")
	elif $builder == "oci-import" then
		[
			@sh "crane push --index temp \(.build.img)",
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
		push: push_command,
	}
;
