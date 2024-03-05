#!/usr/bin/env bash
set -Eeuo pipefail

# usage: if ./.any-go-nt.sh builds; then expensive-docker-run-command ... go build -o builds ...; fi

shopt -s globstar

for go in **/**.go go.mod go.sum; do
	for f; do
		if [ "$go" -nt "$f" ]; then
			exit 0
		fi
	done
done

exit 1
