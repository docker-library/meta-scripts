#!/usr/bin/env bash
set -Eeuo pipefail

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"

src="$dir"
dst="$dir"
tmp='/tmp'
goDir='/go'

msys=
cygwin=
case "$(uname -o)" in
	Msys)
		msys=1
		;;
	Cygwin)
		cygwin=1
		;;
esac
if [ -n "${msys:-$cygwin}" ] && command -v cygpath > /dev/null; then
	src="$(cygpath --windows "$dst")"
fi
windowsContainers=
serverOs="$(docker version --format '{{ .Server.Os }}')"
if [ "$serverOs" = 'windows' ]; then
	windowsContainers=1
	# normally we'd want this to match $src so error messages, traces, etc are easier to follow, but $src might be on a non-C: drive letter and not be usable in the container as-is 😭
	dst='C:\app'
	tmp='C:\Temp'
	goDir='C:\go'
fi

args=(
	--interactive --rm --init
	--mount "type=bind,src=$src,dst=$dst"
	--workdir "$dst"
	--tmpfs "$tmp",exec
	--env HOME="$tmp"

	# "go mod" cache is stored in /go/pkg/mod/cache
	--env GOPATH="$goDir"
	--mount type=volume,src=doi-meta-gopath,dst="$goDir"
	--env GOCACHE="$goDir/.cache"

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
	if [ -n "$msys" ] && command -v winpty > /dev/null; then
		winpty=( winpty )
	fi
fi

if [ -z "${GOLANG_IMAGE:-}" ]; then
	go="$(awk '$1 == "go" { print $2; exit }' "$dir/go.mod")"
	if [[ "$go" == *.*.* ]]; then
		go="${go%.*}" # strip to just X.Y
	fi
	GOLANG_IMAGE="golang:$go"

	# handle riscv64 "gracefully" (no golang image yet because no stable distro releases yet)
	{
		if ! docker image inspect --format '.' "$GOLANG_IMAGE" &> /dev/null && ! docker pull "$GOLANG_IMAGE"; then
			if [ -n "${BASHBREW_ARCH:-}" ] && docker buildx inspect "bashbrew-$BASHBREW_ARCH" &> /dev/null; then
				# a very rough hack to avoid:
				#  ERROR: failed to solve: failed to solve with frontend dockerfile.v0: failed to read dockerfile: failed to load cache key: subdir not supported yet
				# (we need buildkit/buildx for --build-context, but newer buildkit than our dockerd might have for build-from-git-with-subdir)
				export BUILDX_BUILDER="bashbrew-$BASHBREW_ARCH"
			fi
			(
				set -x
				# TODO make this more dynamic, less hard-coded 🙈
				# https://github.com/docker-library/golang/blob/ea6bbce8c9b13acefed0f5507336be01f0918f97/1.21/bookworm/Dockerfile
				GOLANG_IMAGE='golang:1.21' # to be explicit
				docker buildx build --load --tag "$GOLANG_IMAGE" --build-context 'buildpack-deps:bookworm-scm=docker-image://buildpack-deps:unstable-scm' 'https://github.com/docker-library/golang.git#ea6bbce8c9b13acefed0f5507336be01f0918f97:1.21/bookworm'
			)
		fi
	} >&2
fi

args+=(
	"$GOLANG_IMAGE"
	"$@"
)

set -x
exec "${winpty[@]}" docker run "${args[@]}"
