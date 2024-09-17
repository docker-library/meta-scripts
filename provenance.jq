# input: "build" object (with "buildId" top level key)
# output: list of image tags
def tags:
	[
		.source.arches[].tags[],
		.source.arches[].archTags[],
		.build.img
	]
;

# input: "tags" object with image digest and platform arguments
# output: json object for in-toto provenance subject field
def subjects($platform; $digest):
	($digest | split(":")) as $splitDigest
	| {
		"name": "pkg:docker/\(.)?platform=\($platform)",
		"digest": {
			($splitDigest[0]): $splitDigest[1],
		}
	}
;

# input: GITHUB context
# output: json object for in-toto provenance external parameters field
def github_external_parameters($github):
	($github.workflow_ref | ltrimstr($github.repository + "/") | split("@")) as $workflowRefSplit
	| {
		inputs: $github.event.inputs,
		workflow: {
			ref: $workflowRefSplit[1],
			repository: ($github.server_url + "/" + $github.repository),
			path: $workflowRefSplit[0],
			digest: { gitCommit: $github.workflow_sha },
		}
	}
;

# input: "build" object with platform and image digest
# output: json object for in-toto provenance statement
def github_actions_provenance:
	(env.GITHUB_CONTEXT | fromjson) as $github |
	(.source.arches[].platformString | @uri) as $platform |
	{
		_type: "https://in-toto.io/Statement/v1",
		subject: . | tags | map(subjects($platform; $digest)),
		predicateType: "https://slsa.dev/provenance/v1",
		predicate: {
			buildDefinition: {
				buildType: "https://actions.github.io/buildtypes/workflow/v1",
				externalParameters: github_external_parameters($github),
				internalParameters: {
					github: {
						event_name: $github.event_name,
						repository_id: $github.repository_id,
						repository_owner_id: $github.repository_owner_id,
						runner_environment: "github-hosted"
					}
				},
				resolvedDependencies: [{
					uri: ("git+"+$github.server_url+"/"+$github.repository+"@"+$github.ref),
					digest: { "gitCommit": $github.sha }
				}]
			},
			runDetails: {
				# builder.id identifies the transitive closure of the trusted build platform evalution.
				# any changes that alter security properties or build level must update this ID and rotate the signing key.
				# https://slsa.dev/spec/v1.0/provenance#builder
				builder: {
					id: ($github.server_url+"/"+$github.workflow_ref),
				},
				metadata: {
					invocationId: ($github.server_url+"/"+$github.repository+"/actions/runs/"+$github.run_id+"/attempts/"+$github.run_attempt),
				}
			}
		}
	}
;
