#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"

user="$(id -u):$(id -g)"
args=(
	--interactive --rm --init
	--user "$user"
	--mount "type=bind,src=$dir,dst=$dir"
	--workdir "$dir"
	--tmpfs /tmp,exec
	--env HOME=/tmp

	# "go mod" cache is stored in /go/pkg/mod/cache
	--env GOPATH=/go
	--mount type=volume,src=doi-meta-gopath,dst=/go
	--env GOCACHE=/go/.cache

	--env "CGO_ENABLED=${CGO_ENABLED-0}"
	--env "GOTOOLCHAIN=${GOTOOLCHAIN-local}"
	--env GOCOVERDIR # https://go.dev/doc/build-cover
	--env GODEBUG
	--env GOFLAGS
	--env GOOS --env GOARCH
	--env GO386
	--env GOAMD64
	--env GOARM

	# hack hack hack (useful for "go run" during dev/test)
	--env DOCKERHUB_PUBLIC_PROXY
	--env DOCKERHUB_PUBLIC_PROXY_HOST
)
if [ -t 0 ] && [ -t 1 ]; then
	args+=( --tty )
fi
go="$(awk '$1 == "go" { print $2; exit }' "$dir/go.mod")"
if [[ "$go" == *.*.* ]]; then
	go="${go%.*}" # strip to just X.Y
fi
args+=(
	"golang:$go"
	"$@"
)
set -x
exec docker run "${args[@]}"
