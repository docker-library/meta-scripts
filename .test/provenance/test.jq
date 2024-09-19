include "provenance";
include "jenkins";

[
	first(.[] | select(.build.arch == "amd64" and .build.resolved)),
	first(.[] | select(.build.arch == "windows-amd64" and .build.resolved)),
	empty # trailing comma

	| (.build.resolved.annotations["org.opencontainers.image.ref.name"] | split("@")[1]) as $digest

	# some faked GitHub event data so we can ~test the provenance generation
	| gha_payload as $payload
	| {
		event: $payload,
		event_name: "workflow_dispatch",
		ref: "refs/heads/\($payload.ref)",
		repository: "docker-library/meta",
		repository_id: "1234",
		repository_owner_id: "5678",
		run_attempt: "2",
		run_id: "9001",
		server_url: "https://github.com",
		sha: "0123456789abcdef0123456789abcdef01234567",
		workflow_ref: "docker-library/meta/.github/workflows/build.yml@refs/heads/\($payload.ref)",
		workflow_sha: "0123456789abcdef0123456789abcdef01234567",
	} as $github
	| {
		environment: "github-hosted",
	} as $runner

	| github_actions_provenance($github; $runner; $digest)
]
