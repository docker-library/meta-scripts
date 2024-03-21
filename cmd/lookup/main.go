package main

// a simple utility for debugging "registry.SynthesizeIndex" (similar to / the next evolution of "bashbrew remote arches --json")

import (
	"context"
	"encoding/json"
	"os"
	"os/signal"

	"github.com/docker-library/meta-scripts/registry"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	for _, img := range os.Args[1:] {
		ref, err := registry.ParseRef(img)
		if err != nil {
			panic(err)
		}

		index, err := registry.SynthesizeIndex(ctx, ref)
		if err != nil {
			panic(err)
		}

		e := json.NewEncoder(os.Stdout)
		e.SetIndent("", "\t")
		if err := e.Encode(index); err != nil {
			panic(err)
		}
	}
}
