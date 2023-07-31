#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"

# example:
#   jq 'map_values(select(.build.arch == env.BASHBREW_ARCH))' builds.json | .scripts/needs-build.sh

exec jq -L"$dir" '
	include "meta";
	map_values(
		select(needs_build)
		| .commands = {
			pull: pull_command,
			build: build_command,
			push: push_command,
		}
	)
' "$@"
