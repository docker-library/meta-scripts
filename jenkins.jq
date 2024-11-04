include "meta";

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
		ref: "main",
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

# input: full "build" object list (with "buildId" top level key)
# output: filtered build list { "buildId value": { build object } }
def get_arch_queue($arch):
	map_values(
		select(
			needs_build
			and .build.arch == $arch
		)
		|  if .build.arch | IN("amd64", "i386", "windows-amd64") then
			# "GHA" architectures (anything we add a "gha_payload" to will be run on GHA in the queue)
			.gha_payload = (gha_payload | @json)
		else . end
		| .identifier = .source.arches[.build.arch].tags[0]
	)
;
def get_arch_queue:
	get_arch_queue(env.BASHBREW_ARCH)
;

# input: filtered "needs_build" build object list, like from get_raw_queue
# output: simplified list of builds with record of (build/trigger) count and number of current skips
def jobs_record($pastJobs):
	map_values(
		.identifier as $identifier
		| $pastJobs[.buildId] // { count: 0, skips: 0 }
		| .identifier = $identifier
		# start skipping after 24 attempts, try once every 24 skips
		| if .count > 24 and .skips < 24 then
			.skips += 1
		else
			# these ones shold be built
			.skips = 0
			| .count += 1
		end
	)
;

# input: filtered "needs_build" build object list, like from get_raw_queue
#        newJobs list, output of jobs_record: used for filtering and sorting the queue
# ouput: sorted build queue with skipped items removed
def filter_skips_queue($newJobs):
	map(
		select(
			$newJobs[.buildId].skips == 0
		)
	)
	# this Jenkins job exports a JSON file that includes the number of attempts so far per failing buildId so that this can sort by attempts which means failing builds always live at the bottom of the queue (sorted by the number of times they have failed, so the most failing is always last)
	| sort_by($newJobs[.buildId].count)
;
