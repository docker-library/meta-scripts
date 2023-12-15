# input: list of build objects i.e., builds.json
# output: stream of crane copy command strings
def crane_deploy_commands:
	reduce (.[] | select(.build.resolved and .build.arch == env.BASHBREW_ARCH)) as $i ({};
		.[ $i.source.arches[].archTags[] ] += [
			$i.build.resolved
			| .index.ref // .manifest.ref
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
