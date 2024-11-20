[
	# add new test cases here
	# each item will be used for each architecture generated
	# [ ".build.resloved", "count", "skips" ]
	[ null, 1, 0 ], # buildable, tried once
	[ null, 23, 0 ], # buildable, tried many but less than skip threshold
	[ null, 24, 0 ], # buildable, tried many, just on skip threshold
	[ null, 25, 23 ], # buildable, final skip
	[ null, 25, 24 ], # buildable, no longer skipped
	[ {}, 3, 0 ], # build "complete" (not queued or skipped)
	empty # trailing comma
]
| map(
	("amd64", "arm32v7") as $arch
	| ([ $arch, .[] | tostring ] | join("-")) as $buildId
	| {
		# give our inputs cuter names
		resolved: .[0],
		count: .[1],
		skips: .[2],
	}
	| [
		{
			count,
			skips,
		},
		{
			$buildId,
			build: {
				$arch,
				resolved,
			},
			"source": {
				"arches": {
					($arch): {
						"tags": ["fake:\($buildId)"]
					},
				},
			},
		},
		empty # trailing comma
	]
	| map({ ($buildId): . })
)
| transpose
| map(add)
| { pastJobs: .[0], builds: .[1] }
