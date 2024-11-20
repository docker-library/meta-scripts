// one job per arch (for now) that triggers builds for all unbuilt images
properties([
	disableConcurrentBuilds(),
	disableResume(),
	durabilityHint('PERFORMANCE_OPTIMIZED'),
	pipelineTriggers([
		upstream(threshold: 'UNSTABLE', upstreamProjects: '../meta'),
	]),
])

env.BASHBREW_ARCH = env.JOB_NAME.minus('/trigger').split('/')[-1] // "windows-amd64", "arm64v8", etc

def queue = []
def breakEarly = false // thanks Jenkins...

// string filled with all images needing build and whether they were skipped this time for recording after queue completion
// { buildId: { "count": 1, skip: 0, ... }, ... }
def currentJobsJson = ''

node {
	stage('Checkout') {
		checkout(scmGit(
			userRemoteConfigs: [[
				url: 'https://github.com/docker-library/meta.git',
				name: 'origin',
			]],
			branches: [[name: '*/main']],
			extensions: [
				cloneOption(
					noTags: true,
					shallow: true,
					depth: 1,
				),
				submodule(
					parentCredentials: true,
					recursiveSubmodules: true,
					trackingSubmodules: true,
				),
				cleanBeforeCheckout(),
				cleanAfterCheckout(),
				[$class: 'RelativeTargetDirectory', relativeTargetDir: 'meta'],
			],
		))
	}

	dir('meta') {
		stage('Queue') {
			// using pastJobsJson, sort the needs_build queue so that previously attempted builds always live at the bottom of the queue
			// list of builds that have been failing and will be skipped this trigger
			def queueAndFailsJson = sh(returnStdout: true, script: '''
				if \\
					! wget --timeout=5 -qO past-jobs.json "$JOB_URL/lastSuccessfulBuild/artifact/past-jobs.json" \\
					|| ! jq 'empty' past-jobs.json \\
				; then
					# temporary migration of old data
					if ! wget --timeout=5 -qO past-jobs.json "$JOB_URL/lastSuccessfulBuild/artifact/pastFailedJobs.json" || ! jq 'empty' past-jobs.json; then
						echo '{}' > past-jobs.json
					fi
				fi
				jq -c -L.scripts --slurpfile pastJobs past-jobs.json '
					include "jenkins";
					get_arch_queue as $rawQueue
					| $rawQueue | jobs_record($pastJobs[0]) as $newJobs
					| $rawQueue | filter_skips_queue($newJobs) as $filteredQueue
					| (
						($rawQueue | length) - ($filteredQueue | length)
					) as $skippedCount
					# queue, skips/builds record, number of skipped items
					| $filteredQueue, $newJobs, $skippedCount
				' builds.json
			''').tokenize('\r\n')

			def queueJson = queueAndFailsJson[0]
			currentJobsJson = queueAndFailsJson[1]
			def skips = queueAndFailsJson[2]
			//echo(queueJson)

			def jobName = ''
			if (queueJson && queueJson != '[]') {
				queue = readJSON(text: queueJson)
				jobName += 'queue: ' + queue.size()
			} else {
				jobName += 'queue: 0'
				breakEarly = true
			}
			if (skips > 0 ) {
				jobName += ' skip: ' + skips
				// queue to build might be empty, be we still need to record these skipped builds
				breakEarly = false
			}
			currentBuild.displayName = jobName + ' (#' + currentBuild.number + ')'
		}
	}
}

// with an empty queue and nothing to skip we can end early
if (breakEarly) { return } // thanks Jenkins...

// new data to be added to the past-jobs.json
// { lastTime: unixTimestamp, url: "" }
def buildCompletionData = [:]

for (buildObj in queue) {
	stage(buildObj.identifier) {
		//def json = writeJSON(json: buildObj, returnText: true)
		//echo(json) // for debugging/data purposes

		// "catchError" to set "stageResult" :(
		catchError(message: 'Build of "' + buildObj.identifier + '" failed', buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
			if (buildObj.gha_payload) {
				node {
					withEnv([
						'payload=' + buildObj.gha_payload,
					]) {
						withCredentials([
							string(
								variable: 'GH_TOKEN',
								credentialsId: 'github-access-token-docker-library-bot-meta',
							),
						]) {
							sh '''
								set -u +x

								# https://docs.github.com/en/free-pro-team@latest/rest/actions/workflows?apiVersion=2022-11-28#create-a-workflow-dispatch-event
								curl -fL \
									-X POST \
									-H 'Accept: application/vnd.github+json' \
									-H "Authorization: Bearer $GH_TOKEN" \
									-H 'X-GitHub-Api-Version: 2022-11-28' \
									https://api.github.com/repos/docker-library/meta/actions/workflows/build.yml/dispatches \
									-d "$payload"
							'''
						}
					}
					// record that GHA was triggered (for tracking continued triggers that fail to push an image)
					buildCompletionData[buildObj.buildId] = [
						lastTime: System.currentTimeMillis() / 1000, // convert to seconds
						url: currentBuild.absoluteUrl,
					]
				}
			} else {
				def res = build(
					job: 'build',
					parameters: [
						string(name: 'buildId', value: buildObj.buildId),
					],
					propagate: false,
					quietPeriod: 5, // seconds
				)
				// record the job failure
				buildCompletionData[buildObj.buildId] = [
					lastTime: (res.startTimeInMillis + res.duration) / 1000, // convert to seconds
					url: res.absoluteUrl,
				]
				if (res.result != 'SUCCESS') {
					// set stage result via catchError
					error(res.result)
				}
			}
		}
	}
}

// save currentJobs so we can use it next run as pastJobs
node {
	def buildCompletionDataJson = writeJSON(json: buildCompletionData, returnText: true)
	withEnv([
		'buildCompletionDataJson=' + buildCompletionDataJson,
		'currentJobsJson=' + currentJobsJson,
	]) {
		stage('Archive') {
			dir('builds') {
				deleteDir()
				sh '''#!/usr/bin/env bash
					set -Eeuo pipefail -x

					jq <<<"$currentJobsJson" '
						# merge the two objects recursively, preferring data from "buildCompletionDataJson"
						. * ( env.buildCompletionDataJson | fromjson )
					' | tee past-jobs.json
				'''
				archiveArtifacts(
					artifacts: '*.json',
					fingerprint: true,
					onlyIfSuccessful: true,
				)
			}
		}
	}
}
