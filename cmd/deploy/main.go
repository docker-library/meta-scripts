package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"sync"

	"github.com/docker-library/meta-scripts/registry"

	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
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

	// a set of RWMutex objects for synchronizing the pushing of "child" objects before their parents later in the list of documents
	// for every RWMutex, it will be *write*-locked during push, and *read*-locked during reading (which means we won't limit the parallelization of multiple parents after a given child is pushed, but we will stop parents from being pushed before their children)
	childMutexes := sync.Map{}
	wg := sync.WaitGroup{}

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

		var logSuffix string = " (" + string(raw.Type) + ") "
		if normal.CopyFrom != nil {
			// normal copy (one repo/registry to another)
			logSuffix = " 🤝" + logSuffix + normal.CopyFrom.String()
			// "localhost:32774/test 🤝 (manifest) tianon/test@sha256:4077658bc7e39f02f81d1682fe49f66b3db2c420813e43f5db0c53046167c12f"
		} else {
			// push (raw/embedded blob or manifest data)
			logSuffix = " 🦾" + logSuffix + string(refsDigest)
			// "localhost:32774/test 🦾 (blob) sha256:1a51828d59323e0e02522c45652b6a7a44a032b464b06d574f067d2358b0e9f1"
		}
		startedPrefix := "❔ "
		successPrefix := "✅ "
		failurePrefix := "❌ "

		// locks are per-digest, but refs might be 20 tags on the same digest, so we need to get one write lock per repo@digest and release it when the first tag completes, and every other tag needs a read lock
		seenRefs := map[string]bool{}

		for _, ref := range normal.Refs {
			ref := ref // https://github.com/golang/go/issues/60078

			necessaryReadLockRefs := []registry.Reference{}

			// before parallelization, collect the pushing "child" mutex we need to lock for writing right away (but only for the first entry)
			var mutex *sync.RWMutex
			if ref.Digest != "" {
				lockRef := ref
				lockRef.Tag = ""
				lockRefStr := lockRef.String()
				if seenRefs[lockRefStr] {
					// if we've already seen this specific ref for this input, we need a read lock, not a write lock (since they're per-repo@digest)
					necessaryReadLockRefs = append(necessaryReadLockRefs, lockRef)
				} else {
					seenRefs[lockRefStr] = true
					lock, _ := childMutexes.LoadOrStore(lockRefStr, &sync.RWMutex{})
					mutex = lock.(*sync.RWMutex)
					// if we have a "child" mutex, lock it immediately so we don't create a race between inputs
					mutex.Lock() // (this gets unlocked in the goroutine below)
					// this is sane to lock here because interdependent inputs are required to be in-order (children first), so if this hangs it's 100% a bug in the input order
				}
			}

			// make a (deep) copy of "normal" so that we can use it in a goroutine ("normal.do" is not safe for concurrent invocation)
			normal := normal.clone()

			wg.Add(1)
			go func() {
				defer wg.Done()

				if mutex != nil {
					defer mutex.Unlock()
				}

				// before we start this job (parallelized), if it's a raw data job we need to parse the raw data and see if any of the "children" are objects we're still in the process of pushing (from a previously parallel job)
				if len(normal.Data) > 2 { // needs to at least be bigger than "{}" for us to care (anything else either doesn't have data or can't have children)
					// explicitly ignoring errors because this might not actually be JSON (or even a manifest at all!); this is best-effort
					// TODO optimize this by checking whether normal.Data matches "^\s*{.+}\s*$" first so we have some assurance it might work before we go further?
					manifestChildren, _ := registry.ParseManifestChildren(normal.Data)
					childDescs := []ocispec.Descriptor{}
					childDescs = append(childDescs, manifestChildren.Manifests...)
					if manifestChildren.Config != nil {
						childDescs = append(childDescs, *manifestChildren.Config)
					}
					childDescs = append(childDescs, manifestChildren.Layers...)
					for _, childDesc := range childDescs {
						childRef := ref
						childRef.Digest = childDesc.Digest
						necessaryReadLockRefs = append(necessaryReadLockRefs, childRef)

						// these read locks are cheap, so let's be aggressive with our "lookup" refs too
						if lookupRef, ok := normal.Lookup[childDesc.Digest]; ok {
							lookupRef.Digest = childDesc.Digest
							necessaryReadLockRefs = append(necessaryReadLockRefs, lookupRef)
						}
						if fallbackRef, ok := normal.Lookup[""]; ok {
							fallbackRef.Digest = childDesc.Digest
							necessaryReadLockRefs = append(necessaryReadLockRefs, fallbackRef)
						}
					}
				}
				// we don't *know* that all the lookup references are children, but if any of them have an explicit digest, let's treat them as potential children too (which is fair, because they *are* explicit potential references that it's sane to make sure exist)
				for digest, lookupRef := range normal.Lookup {
					necessaryReadLockRefs = append(necessaryReadLockRefs, lookupRef)
					if digest != lookupRef.Digest {
						lookupRef.Digest = digest
						necessaryReadLockRefs = append(necessaryReadLockRefs, lookupRef)
					}
				}
				// if we're going to do a copy, we need to *also* include the artifact we're copying in our list
				if normal.CopyFrom != nil {
					necessaryReadLockRefs = append(necessaryReadLockRefs, *normal.CopyFrom)
				}
				// ok, we've built up a list, let's start grabbing (ro) mutexes
				seenChildren := map[string]bool{}
				for _, lockRef := range necessaryReadLockRefs {
					lockRef.Tag = ""
					if lockRef.Digest == "" {
						continue
					}
					lockRefStr := lockRef.String()
					if seenChildren[lockRefStr] {
						continue
					}
					seenChildren[lockRefStr] = true
					lock, _ := childMutexes.LoadOrStore(lockRefStr, &sync.RWMutex{})
					lock.(*sync.RWMutex).RLock()
					defer lock.(*sync.RWMutex).RUnlock()
				}

				logText := ref.StringWithKnownDigest(refsDigest) + logSuffix
				fmt.Println(startedPrefix + logText)
				desc, err := normal.do(ctx, ref)
				if err != nil {
					fmt.Fprintf(os.Stderr, "%s%s -- ERROR: %v\n", failurePrefix, logText, err)
					panic(err) // TODO exit in a more clean way (we can't use "os.Exit" because that causes *more* errors 😭)
				}
				if ref.Digest == "" && refsDigest == "" {
					logText += "@" + string(desc.Digest)
				}
				fmt.Println(successPrefix + logText)
			}()
		}
	}

	wg.Wait()
}
