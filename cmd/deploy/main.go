package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	// TODO --dry-run ?

	// TODO the best we can do on whether or not this actually updated tags is "yes, definitely (we had to copy some children)" and "maybe (we didn't have to copy any children)", but we should maybe still output those so we can trigger put-shared based on them (~immediately on "definitely" and with some medium delay on "maybe")

	// see "input.go" and "inputRaw" for details on the expected JSON input format

	// we pass through "jq" to pretty-print any JSON-form data fields with sane whitespace
	jq := exec.Command("jq", "del(.data), .data")
	jq.Stdin = os.Stdin
	jq.Stderr = os.Stderr

	stdout, err := jq.StdoutPipe()
	if err != nil {
		panic(err)
	}
	if err := jq.Start(); err != nil {
		panic(err)
	}

	dec := json.NewDecoder(stdout)
	for dec.More() {
		var raw inputRaw
		if err := dec.Decode(&raw); err != nil {
			panic(err)
		}
		if err := dec.Decode(&raw.Data); err != nil {
			panic(err)
		}

		normal, err := NormalizeInput(raw)
		if err != nil {
			panic(err)
		}
		refsDigest := normal.Refs[0].Digest

		if normal.CopyFrom == nil {
			fmt.Printf("Pushing %s %s:\n", raw.Type, refsDigest)
		} else {
			fmt.Printf("Copying %s %s:\n", raw.Type, *normal.CopyFrom)
		}

		for _, ref := range normal.Refs {
			fmt.Printf(" - %s", ref.StringWithKnownDigest(refsDigest))
			desc, err := normal.Do(ctx, ref)
			if err != nil {
				fmt.Fprintf(os.Stderr, " -- ERROR: %v\n", err)
				os.Exit(1)
				return
			}
			if ref.Digest == "" && refsDigest == "" {
				fmt.Printf("@%s", desc.Digest)
			}
			fmt.Println()
		}

		fmt.Println()
	}
}
