#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"

[ -n "$BASHBREW_ARCH" ]

exec jq -L"$dir" '
	include "meta";
	map_values(
		select(needs_build and .build.arch == env.BASHBREW_ARCH)
		| .commands = {
			pull: pull_command,
			build: build_command,
			push: push_command,
		}
	)
' "$@"
