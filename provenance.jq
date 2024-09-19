# input: "build" object with platform and image digest
#   $github: "github" context; CONTAINS SENSITIVE INFORMATION (https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/accessing-contextual-information-about-workflow-runs#github-context)
#   $runner: "runner" context; https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/accessing-contextual-information-about-workflow-runs#runner-context
#   $digest: the OCI image digest for the just-built image (normally in .build.resolved.annotations["org.opencontainers.image.ref.name"] but only post-push/regeneration and we haven't pushed yet)
#
# output: in-toto provenance statement (https://slsa.dev/spec/v1.0/provenance)
#   see also: https://github.com/actions/buildtypes/tree/main/workflow/v1
def github_actions_provenance($github; $runner; $digest):
	if $github.event_name != "workflow_dispatch" then error("error: '\($github.event_name)' is not a supported event type for provenance generation") else
		{
			_type: "https://in-toto.io/Statement/v1",
			subject: [
				($digest | split(":")) as $splitDigest
				| (.source.arches[.build.arch].platformString) as $platform
				| (
					.source.arches[.build.arch].tags[],
					.source.arches[.build.arch].archTags[],
					.build.img,
					empty # trailing comma
				)
				| {
					# https://github.com/package-url/purl-spec/blob/b33dda1cf4515efa8eabbbe8e9b140950805f845/PURL-TYPES.rst#docker (this matches what BuildKit generates as of 2024-09-18; "oci" would also be a reasonable choice, but would require signer and policy changes to support, and be more complex to generate accurately)
					name: "pkg:docker/\(.)?platform=\($platform | @uri)",
					digest: { ($splitDigest[0]): $splitDigest[1] },
				}
			],
			predicateType: "https://slsa.dev/provenance/v1",
			predicate: {
				buildDefinition: {
					buildType: "https://actions.github.io/buildtypes/workflow/v1",
					externalParameters: {
						workflow: {
							# TODO this matches how this is documented/suggested in GitHub's buildType documentation, but does not account for the workflow file being in a separate repository at a separate ref from the "source" (which the "workflow_ref" field *does* account for), so that would/will change how we need to calculate these values if we ever do that (something like "^(?<repo>[^/]+/[^/]+)/(?<path>.*)@(?<ref>refs/.*)$" on $github.workflow_ref ?)
							ref: $github.ref,
							repository: ($github.server_url + "/" + $github.repository),
							path: (
								$github.workflow_ref
								| ltrimstr($github.repository + "/")
								| rtrimstr("@" + $github.ref)
								| if contains("@") then error("parsing 'workflow_ref' failed: '\(.)'") else . end
							),
							# not required, but useful/important (and potentially but unlikely different from $github.sha used in resolvedDependencies below):
							digest: { gitCommit: $github.workflow_sha },
						},
						inputs: $github.event.inputs, # https://docs.github.com/en/webhooks/webhook-events-and-payloads#workflow_dispatch
					},
					internalParameters: {
						github: {
							event_name: $github.event_name,
							repository_id: $github.repository_id,
							repository_owner_id: $github.repository_owner_id,
							runner_environment: $runner.environment,
						},
					},
					resolvedDependencies: [
						{
							uri: "git+\($github.server_url)/\($github.repository)@\($github.ref)",
							digest: { "gitCommit": $github.sha },
						},
						# TODO figure out a way to include resolved action SHAs from "uses:" expressions
						# TODO include more resolved dependencies
						empty # tailing comma
					],
				},
				runDetails: {
					# builder.id identifies the transitive closure of the trusted build platform evalution.
					# any changes that alter security properties or build level must update this ID and rotate the signing key.
					# https://slsa.dev/spec/v1.0/provenance#builder
					builder: {
						id: ($github.server_url + "/" + $github.workflow_ref),
					},
					metadata: {
						invocationId: ($github.server_url + "/" + $github.repository + "/actions/runs/" + $github.run_id + "/attempts/" + $github.run_attempt)
					},
				},
			},
		}
	end
;
