#!/usr/bin/env bash
set -eo pipefail

# Split the sources preserviung the order
mkdir -p out out2 && \
cat sources.json \
    | jq -rc \
        '[keys_unsorted
            | _nwise(10)]
            | to_entries[]
            | tojson
            | @sh' \
    | xargs -I % -n1 jq -rc \
        '[
            $input.key,
            (
                .
                    | to_entries
                    | [
                        .[] |
                            select(
                                .key as $key | any($input.value[] == $key)
                            )
                    ]
                    | from_entries
                    | tojson
            )
        ] | @tsv' \
        sources.json --argjson input '%' \
    | awk '{ f = sprintf("out/%03d.json", $1) ; print $2 >f }'


# Run each file through the build in parallel and output to another temporary file
find out -type f -execdir basename {} ';' | xargs -P $(nproc) -I % -n1 sh -c '.scripts/builds.sh out/% > out2/%'

# Merge the final temporary file and sort the key for a deterministic output
find out2 -type f | xargs jq --sort-keys -s 'add' > build.json

# Remove temporary files
rm -rf out/ out2/
