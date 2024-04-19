#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"

src="$dir"
dst="$dir"
msys=
if [ "$(uname -o)" = 'Msys' ]; then
	msys=1
	if command -v cygpath > /dev/null; then
		src="$(cygpath --windows "$dst")"
	fi
fi
windowsContainers=
serverOs="$(docker version --format '{{ .Server.Os }}')"
if [ "$serverOs" = 'windows' ]; then
	windowsContainers=1
	# normally we'd want this to match $src so error messages, traces, etc are easier to follow, but $src might be on a non-C: drive letter and not be usable in the container as-is 😭
	dst='C:\app'
fi

args=(
	--interactive --rm --init
	--mount "type=bind,src=$src,dst=$dst"
	--workdir "$dst"
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

if [ -z "$windowsContainers" ]; then
	user="$(id -u)"
	user+=":$(id -g)"
	args+=( --user "$user" )
fi

winpty=()
if [ -t 0 ] && [ -t 1 ]; then
	args+=( --tty )
	if [ -n "$msys" ]; then
		winpty=( winpty )
	fi
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
exec "${winpty[@]}" docker run "${args[@]}"
