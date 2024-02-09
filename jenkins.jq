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
