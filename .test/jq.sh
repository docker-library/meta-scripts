#!/usr/bin/env bash
set -Eeuo pipefail

shopt -s nullglob # if * matches nothing, return nothing

dir="$(dirname "$BASH_SOURCE")"
dir="$(readlink -ve "$dir")"

export SOURCE_DATE_EPOCH=0 # TODO come up with a better way for a test to specify it needs things like this (maybe a file that gets sourced/read for options/setup type things?  could also provide args/swap 'out' like our "-r" hank below)

# TODO arguments for choosing a test?  directory?  name?
for t in "$dir/"*"/test.jq"; do
	td="$(dirname "$t")"
	echo -n 'test: '
	basename "$td"
	args=( --tab -L "$dir/.." )
	if [ -s "$td/in.jq" ]; then
		jq "${args[@]}" -n -f "$td/in.jq" > "$td/in.json"
	fi
	args+=( -f "$t" )
	if [ -s "$td/in.json" ]; then
		args+=( "$td/in.json" )
	else
		args+=( -n )
	fi
	out="$td/out.json"
	outs=( "$td/out."* )
	if [ "${#outs[@]}" -eq 1 ]; then
		out="${outs[0]}"
		if [[ "$out" != *.json ]]; then
			args+=( -r )
		fi
	fi
	jq "${args[@]}" > "$out"
done
