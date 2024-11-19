include "jenkins";
.pastJobs as $pastJobs
| .builds
| get_arch_queue("arm32v7") as $rawQueue
| $rawQueue | jobs_record($pastJobs) as $newJobs
| $rawQueue | filter_skips_queue($newJobs) as $filteredQueue
| (
	($rawQueue | length) - ($filteredQueue | length)
) as $skippedCount
# queue, skips/builds record, number of skipped items
| $filteredQueue, $newJobs, $skippedCount
