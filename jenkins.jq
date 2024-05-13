# input: list of build objects i.e., builds.json
# output: stream of crane copy command strings
def crane_deploy_commands:
	reduce (.[] | select(.build.resolved and .build.arch == env.BASHBREW_ARCH)) as $i ({};
		.[ $i.source.arches[$i.build.arch].archTags[] ] += [
			$i.build.resolved.annotations["org.opencontainers.image.ref.name"] // error("\($i.build.img) missing a resolved ref")
			# TODO ideally we'd use .manifests[] here to take advantage of the filtering we've done at previous steps, but then we lose in-index annotations because `crane index append` can't really do that
		]
	)
	| to_entries[]
	| .key as $target
	| .value
	| if length == 1 then
		@sh "crane copy \(.) \($target)"
	else
		@sh "crane index append --tag \($target) " + (map("--manifest " + @sh) | join(" ")) + " --flatten"
	end
;

# input: "build" object (with "buildId" top level key)
# output: json object (to trigger the build on GitHub Actions)
def gha_payload:
	{
		ref: "subset", # TODO back to main
		inputs: (
			{
				buildId: .buildId,
				bashbrewArch: .build.arch,
				firstTag: .source.arches[.build.arch].tags[0],
			} + (
				[ .build.resolvedParents[].manifests[].platform? | select(has("os.version")) | ."os.version" ][0] // ""
				| if . != "" then
					{ windowsVersion: (
						# https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/base-image-lifecycle
						# https://github.com/microsoft/hcsshim/blob/e8208853ff0f7f23fa5d2e018deddff2249d35c8/osversion/windowsbuilds.go
						capture("^10[.]0[.](?<build>[0-9]+)([.]|$)")
						| {
							# since this is specifically for GitHub Actions support, this is limited to the underlying versions they actually support
							# https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners#supported-runners-and-hardware-resources
							"20348": "2022",
							"17763": "2019",
							"": "",
						}[.build] // "unknown"
					) }
				else {} end
			)
		)
	}
;
