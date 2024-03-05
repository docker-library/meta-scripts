package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"

	"github.com/docker-library/meta-scripts/registry"
)

type deployMeta struct {
	Tags      []string          `json:"tags"`
	Manifests map[string]string `json:"manifests"`
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	// TODO --dry-run
	// TODO --verbose (show full index object/JSON)

	// TODO --prefix ? (some way to push to a localhost:5000/ registry instead of Docker Hub, esp. for testing, without having to get some error-prone "jq" expression correct)

	// TODO some way to specify exactly which repo:tags to deploy (arch-specific or otherwise ?  maybe some way to specify a "repo:tag" for which we want to deploy all the arch-specific tags?)

	// TODO the best we can do on whether or not this actually updated tags is "yes, definitely (we had to copy some children)" and "maybe (we didn't have to copy any children)", but we should still output those so we can trigger put-shared based on them (~immediately on "definitely" and with some medium delay on "maybe")

	// TODO some way to provide input to this which combines data from sources.json *and* builds.json to synthesize missing builds from older archTags (if they exist) to prevent the "update makes amd64 disappear" problem

	/*
		input on stdin is a stream of objects which include the keys "tags", "manifests", and "index" where "tags" is the list of tags we want to push to, "index" is the image index object we want to push to them, and "manifests" is a lookup table for if the index fails to push (ie, where to find the children of the index so we can push/blob mount them)
		example:
		{
			"tags": ["example/foo:bar", "example/foo:baz"],
			"manifests": {"sha256:xxx": "example/staging:yyy@sha256:xxx", ...},
			"index": {
				"schemaVersion": 2,
				"mediaType": "application/vnd.oci.image.index.v1+json",
				"manifests": [
					...
				]
			}
		}
	*/
	jq := exec.Command("jq", "del(.index), .index")
	jq.Stdin = os.Stdin

	stdout, err := jq.StdoutPipe()
	if err != nil {
		panic(err)
	}
	if err := jq.Start(); err != nil {
		panic(err)
	}

	dec := json.NewDecoder(stdout)
	for dec.More() {
		var meta registry.PushIndexOp
		if err := dec.Decode(&meta); err != nil {
			panic(err)
		}
		if err := dec.Decode(&meta.Index); err != nil {
			panic(err)
		}

		desc, err := registry.PushIndex(ctx, meta)
		if err != nil {
			panic(err)
		}
		fmt.Printf("Pushed %s (%s) to:\n", desc.Digest, desc.MediaType)
		for _, tag := range meta.Tags {
			fmt.Printf(" - %s\n", tag)
		}
	}
}
