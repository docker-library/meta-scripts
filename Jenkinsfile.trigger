// one job per arch (for now) that triggers builds for all unbuilt images
properties([
	disableConcurrentBuilds(),
	disableResume(),
	durabilityHint('PERFORMANCE_OPTIMIZED'),
	pipelineTriggers([
		githubPush(),
		cron('@hourly'), // run hourly whether we "need" it or not
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
					echo '{}' > past-jobs.json
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
			def skips = queueAndFailsJson[2].toInteger()
			//echo(queueJson)

			def jobName = ''
			if (queueJson && queueJson != '[]') {
				queue = readJSON(text: queueJson)
				jobName += 'queue: ' + queue.size()
			} else {
				jobName += 'queue: 0'
				breakEarly = true
			}
			if (skips > 0) {
				jobName += ' skip: ' + skips
				if (breakEarly) {
					// if we're skipping some builds but the effective queue is empty, we want to set the job as "unstable" instead of successful (so we know there's still *something* that needs to build but it isn't being built right now)
					currentBuild.result = 'UNSTABLE'
				}
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
buildCompletionData = [:]

// list of closures that we can use to wait for the jobs on.
def waitQueue = [:]
def waitQueueClosure(identifier, buildId, externalizableId) {
	return {
		stage(identifier) {
			// "catchError" to set "stageResult" :(
			catchError(message: 'Build of "' + identifier + '" failed', buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
				def res = waitForBuild(
					runId: externalizableId,
					propagateAbort: true, // allow cancelling this job to cancel all the triggered jobs
				)
				buildCompletionData[buildId] = [
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

// stage to wrap up all the build job triggers that get waited on later
stage('trigger') {
	for (buildObj in queue) {
		if (buildObj.gha_payload) {
			stage(buildObj.identifier) {
				// "catchError" to set "stageResult" :(
				catchError(message: 'Build of "' + buildObj.identifier + '" failed', buildResult: 'UNSTABLE', stageResult: 'FAILURE') {
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
				}
			}
		} else {
			// "catchError" to set "stageResult" :(
			catchError(message: 'Build of "' + buildObj.identifier + '" failed', buildResult: 'UNSTABLE', stageResult: 'FAILURE') {

				// why not parallel these build() invocations?
				// jenkins parallel closures get started in a randomish order, ruining our sorted queue
				def res = build(
					job: 'build',
					parameters: [
						string(name: 'buildId', value: buildObj.buildId),
						string(name: 'identifier', value: buildObj.identifier),
						string(name: 'windowsVersion', value: buildObj.windowsVersion),
					],
					propagate: false,
					// trigger these quickly so they all get added to Jenkins queue in "queue" order (also using "waitForStart" means we have to wait for the entire "quietPeriod" before we get to move on and schedule more)
					quietPeriod: 1, // seconds
					// we'll wait on the builds in parallel after they are all queued (so our sorted order is the queue order)
					waitForStart: true,
				)
				waitQueue[buildObj.identifier] = waitQueueClosure(buildObj.identifier, buildObj.buildId, res.externalizableId)
			}
		}
	}
}

// wait on all the 'build' jobs that were queued
if (waitQueue.size() > 0) {
	parallel waitQueue
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
						# save firstTime if it is not set yet
						map_values(.firstTime //= .lastTime)
						# merge the two objects recursively, preferring data from "buildCompletionDataJson"
						| . * ( env.buildCompletionDataJson | fromjson )
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
