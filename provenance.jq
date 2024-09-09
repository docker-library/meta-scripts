# input: "build" object (with "buildId" top level key)
# output: array of image tags
def tags:
  .source.arches[].tags[],
  .source.arches[].archTags[],
  .build.img
;

# input: "build" object (with "buildId" top level key)
# output: purl platform query string
def platform_string:
  .source.arches[].platformString | gsub("/"; "%2F")
;

# input: "tags" object with image digest and platform arguments
# output: json object for in-toto provenance subject field
def subjects($platform; $digest):
  {
      "name": ("pkg:docker/" + . + "?platform=" + $platform),
      "digest": {
        "sha256": $digest
      }
  }
;

# input: GITHUB context argument
# output: json object for in-toto provenance external parameters field
def github_external_parameters($context):
($context.workflow_ref | gsub( $context.repository + "/"; "")) as $workflowPathRef |
{
  inputs: $context.event.inputs,
  workflow: {
    ref: ($workflowPathRef | split("@")[1]),
    repository: ($context.server_url + "/" + $context.repository),
    path: ($workflowPathRef | split("@")[0]),
    digest: {sha256: $context.workflow_sha}
  }
}
;

# input: GITHUB context argument
# output: json object for in-toto provenance internal parameters field
def github_internal_parameters($context):
{
  github: {
    event_name: $context.event_name,
    repository_id: $context.repository_id,
    repository_owner_id: $context.repository_owner_id,
  }
}
;

# input: "tags" object with platform, image digest and GITHUB context arguments
# output: json object for in-toto provenance statement
def github_actions_provenance($platform; $digest; $context):
{
  _type: "https://in-toto.io/Statement/v1",
  subject: . | map(subjects($platform; $digest)),
  predicateType: "https://slsa.dev/provenance/v1",
  predicate: {
        buildDefinition: {
            buildType: "https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1",
            externalParameters: github_external_parameters($context),
            internalParameters: github_internal_parameters($context),
            resolvedDependencies: [{
                uri: ("git+"+$context.server_url+"/"+$context.repository+"@"+$context.ref),
                digest: { "gitCommit": $context.sha }
            }]
        },
        runDetails: {
            builder: {
                id: ($context.server_url+"/"+$context.workflow_ref),
            },
            metadata: {
                invocationId: ($context.server_url+"/"+$context.repository+"/actions/runs/"+$context.run_id+"/attempts/"+$context.run_attempt),
            }
        }
    }
}
;
