include "jenkins";
.pastJobs as $pastJobs
| .builds
| get_arch_queue("arm32v7")
# testing with a "now" timestamp of 0
| jobs_record($pastJobs; 0) as $newJobs
| filter_skips_queue($newJobs) as $filteredQueue
| (
	(length) - ($filteredQueue | length)
) as $skippedCount
# queue, skips/builds record, number of skipped items
| $filteredQueue, $newJobs, $skippedCount
