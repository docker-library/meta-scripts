package main

// a simple utility for debugging "registry.SynthesizeIndex" (similar to / the next evolution of "bashbrew remote arches --json")

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/signal"

	"github.com/docker-library/meta-scripts/registry"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	var (
		zeroOpts registry.LookupOptions
		opts     = zeroOpts
	)

	args := os.Args[1:]
	for len(args) > 0 {
		img := args[0]
		args = args[1:]
		switch img {
		case "--type":
			opts.Type = registry.LookupType(args[0])
			args = args[1:]
			continue
		case "--head":
			opts.Head = true
			continue
		}

		ref, err := registry.ParseRef(img)
		if err != nil {
			panic(err)
		}

		var obj any
		if opts == zeroOpts {
			// if we have no explicit type and didn't request a HEAD, invoke SynthesizeIndex instead of Lookup
			obj, err = registry.SynthesizeIndex(ctx, ref)
			if err != nil {
				panic(err)
			}
		} else {
			r, err := registry.Lookup(ctx, ref, &opts)
			if err != nil {
				panic(err)
			}
			if r != nil {
				desc := r.Descriptor()
				if opts.Head {
					obj = desc
				} else {
					b, err := io.ReadAll(r)
					if err != nil {
						r.Close()
						panic(err)
					}
					if opts.Type == registry.LookupTypeManifest {
						// if it was a manifest lookup, cast the byte slice to json.RawMessage so we get the actual JSON (not base64)
						obj = json.RawMessage(b)
					} else {
						obj = b
					}
				}
				err = r.Close()
				if err != nil {
					panic(err)
				}
			} else {
				obj = nil
			}
		}

		e := json.NewEncoder(os.Stdout)
		e.SetIndent("", "\t")
		if err := e.Encode(obj); err != nil {
			panic(err)
		}

		// reset state
		opts = zeroOpts
	}

	if opts != zeroOpts {
		panic("dangling --type, --head, etc (without a following reference for it to apply to)")
	}
}
