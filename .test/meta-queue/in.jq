[
	# add new test cases here
	# each item will be used for each architecture generated
	# [ ".build.resloved", "count", "lastTime" ]
	# these are testing against a "now" time of 0
	[ null, 0, null ], # buildable, untried (new build): BUILD
	[ null, 1, 0 ], # buildable, tried once, tried moments ago: BUILD

	[ null, 2, 0 ], # buildable, tried 2 times, tried moments ago: SKIP
	[ null, 2, -1 * 60 * 60 + 1 ], # buildable, tried 2 times, tried just under an hour ago: SKIP
	[ null, 2, -1 * 60 * 60 ], # buildable, tried 2 times, tried an hour ago: BUILD

	[ null, 3, 0 ], # buildable, tried 3 times, tried moments ago: SKIP
	[ null, 3, -2 * 60 * 60 + 1 ], # buildable, tried 3 times, tried under 2 hours ago: SKIP
	[ null, 3, -2 * 60 * 60 ], # buildable, tried 3 times, tried 2 hours ago: BUILD

	[ null, 4, -4 * 60 * 60 + 1 ], # buildable, tried 4 times, tried under 4 hours ago: SKIP
	[ null, 4, -4 * 60 * 60 ], # buildable, tried 4 times, tried 4 hours ago: BUILD

	[ null, 5, -8 * 60 * 60 + 1 ], # buildable, tried 5 times, tried under 8 hours ago: SKIP
	[ null, 5, -8 * 60 * 60 ], # buildable, tried 5 times, tried 8 hours ago: BUILD

	[ null, 6, -16 * 60 * 60 + 1 ], # buildable, tried 6 times, tried under 16 hours ago: SKIP
	[ null, 6, -16 * 60 * 60 ], # buildable, tried 6 times, tried 16 hours ago: BUILD

	[ null, 7, -32 * 60 * 60 + 1 ], # buildable, tried 7 times, tried under 32 hours ago: SKIP
	[ null, 7, -32 * 60 * 60 ], # buildable, tried 7 times, tried 32 hours ago: BUILD

	[ null, 8, -32 * 60 * 60 + 1 ], # buildable, tried 8 times, tried under 32 hours ago: SKIP (max)
	[ null, 8, -32 * 60 * 60 ], # buildable, tried 8 times, tried 32 hours ago: BUILD
	[ {}, 3, 0 ], # build "complete" (not queued or skipped)
	empty # trailing comma
]
| map(
	("amd64", "arm32v7") as $arch
	| {
		# give our inputs cuter names
		resolved: .[0],
		count: .[1],
		lastTime: .[2],
	}
	| (
		.lastTime = ((.lastTime // 0) | todate) # convert lastTime to a datetime for prettier output
		| [ $arch, .[] | tostring ] | join("-")
	) as $buildId
	| [
		{
			count,
			lastTime,
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
