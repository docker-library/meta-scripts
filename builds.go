package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"

	"github.com/docker-library/meta-scripts/om"
	"github.com/docker-library/meta-scripts/registry"

	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

var concurrency = 1000

type MetaSource struct {
	SourceID string   `json:"sourceId"`
	Tags     []string `json:"tags"`
	Arches   map[string]struct {
		Parents om.OrderedMap[struct {
			SourceID *string `json:"sourceId"`
			Pin      *string `json:"pin"`
		}]
	}
}

type BuildIDParts struct {
	SourceID string                `json:"sourceId"`
	Arch     string                `json:"arch"`
	Parents  om.OrderedMap[string] `json:"parents"`
}

type MetaBuild struct {
	BuildID string `json:"buildId"`
	Build   struct {
		Img      string         `json:"img"`
		Resolved *ocispec.Index `json:"resolved"`
		BuildIDParts
		ResolvedParents om.OrderedMap[ocispec.Index] `json:"resolvedParents"`
	} `json:"build"`
	Source json.RawMessage `json:"source"`
}

var (
	// keys are image/tag names, values are functions that return either *ocispec.Index or error
	cacheResolve = sync.Map{}
	cacheFile    string
)

func resolveIndex(ctx context.Context, img string, diskCacheForSure bool) (*ocispec.Index, error) {
	ref, err := registry.ParseRefNormalized(img)
	if err != nil {
		return nil, err
	}
	if ref.Digest != "" {
		// we use "ref" as a cache key, so if we have an explicit digest, ditch any tag data
		ref.Tag = ""
	} else if ref.Tag == "" {
		ref.Tag = "latest"
	}
	refString := ref.String()

	cacheFunc, wasCached := cacheResolve.LoadOrStore(refString, sync.OnceValues(func() (*ocispec.Index, error) {
		return registry.SynthesizeIndex(ctx, ref)
	}))

	index, err := cacheFunc.(func() (*ocispec.Index, error))()
	if err != nil {
		return nil, err
	}
	if index == nil {
		return nil, nil
	}

	if !wasCached {
		fmt.Fprintf(os.Stderr, "NOTE: lookup %s -> %s\n", img, strings.TrimPrefix(index.Annotations[ocispec.AnnotationRefName], refString))
	}

	if !diskCacheForSure {
		// if we don't know we should cache this lookup for sure, the answer is whether it's a by-digest lookup :)
		diskCacheForSure = (ref.Digest != "")
	}
	if diskCacheForSure {
		saveCacheMutex.Lock()
		if saveCache != nil {
			saveCache.Indexes[refString] = index
		}
		saveCacheMutex.Unlock()
	}

	return index, nil
}

func resolveArchIndex(ctx context.Context, img string, arch string, diskCacheForSure bool) (*ocispec.Index, error) {
	index, err := resolveIndex(ctx, img, diskCacheForSure)
	if err != nil {
		return nil, err
	}
	if index == nil {
		return index, nil
	}

	// janky little "deep copy" to avoid mutating the original index (and screwing up our cache / other arch lookups of the same image)
	indexCopy := *index
	indexCopy.Manifests = nil
	indexCopy.Manifests = append(indexCopy.Manifests, index.Manifests...)
	// TODO top-level *and* nested Annotations/URLs/Platform also? (we don't currently mutate any of those, so not critical)
	index = &indexCopy

	i := 0 // https://go.dev/wiki/SliceTricks#filter-in-place (used to delete references that don't belong to the selected architecture)
	for _, m := range index.Manifests {
		if m.Annotations[registry.AnnotationBashbrewArch] != arch {
			continue
		}
		index.Manifests[i] = m
		i++
	}
	index.Manifests = index.Manifests[:i] // https://go.dev/wiki/SliceTricks#filter-in-place

	// TODO set an annotation on the index to specify whether or not we actually filtered anything (or whether it's safe to copy the original index as-is during arch-specific deploy instead of reconstructing it from all the parts); maybe a list of digests that were skipped/excluded?
	// see matching TODO over in registry.SynthesizeIndex (which this needs to also respect/keep/supplement, if/when we implement it here)

	if len(index.Manifests) == 0 {
		return nil, nil
	}

	// TODO if we have more than one *actual* image match for arch (not just an attestation), this should error!! (would mean something like index/manifest list with multiple os.version values for Windows - we avoid this in DOI today, but we don't have any automated *checks* for it, so the current state is a little precarious)

	return index, nil
}

type cacheFileContents struct {
	Indexes map[string]*ocispec.Index `json:"indexes"`
}

var (
	saveCache      *cacheFileContents
	saveCacheMutex sync.Mutex
)

func loadCacheFromFile() error {
	if cacheFile == "" {
		return nil
	}

	// now that we know we have a file we want cache to go into (and come from), let's initialize the "saveCache" (which will be written when the whole process is done / we're successful, and *only* caches staging images)
	saveCacheMutex.Lock()
	saveCache = &cacheFileContents{Indexes: map[string]*ocispec.Index{}}
	saveCacheMutex.Unlock()

	f, err := os.Open(cacheFile)
	if os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	defer f.Close()

	var cache cacheFileContents
	err = json.NewDecoder(f).Decode(&cache) // *technically*, this will silently ignore garbage (or extra documents) at the end of the file, but it's for our cache file so it's not really an issue for us (the only input to this should be our own output)
	if err != nil {
		return err
	}

	for img, index := range cache.Indexes {
		index := index // https://github.com/golang/go/issues/60078
		fun, _ := cacheResolve.LoadOrStore(img, sync.OnceValues(func() (*ocispec.Index, error) {
			return index, nil
		}))
		index2, err := fun.(func() (*ocispec.Index, error))()
		if err != nil {
			// this should never happen (hence panic vs return) 🙈
			panic(err)
		}
		if index2 != index {
			panic("index2 != index??? " + img)
		}
	}

	return nil
}

func saveCacheToFile() error {
	saveCacheMutex.Lock()
	defer saveCacheMutex.Unlock()

	if saveCache == nil || cacheFile == "" {
		return nil
	}

	f, err := os.Create(cacheFile)
	if err != nil {
		return err
	}
	defer f.Close()

	enc := json.NewEncoder(f)
	enc.SetIndent("", "\t")

	err = enc.Encode(saveCache)
	if err != nil {
		return err
	}

	return nil
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	sourcesJsonFile := os.Args[1] // "sources.json"

	// support "--cache foo.json" and "--cache=foo.json"
	if sourcesJsonFile == "--cache" && len(os.Args) >= 4 {
		cacheFile = os.Args[2]
		sourcesJsonFile = os.Args[3]
	} else if cf, ok := strings.CutPrefix(sourcesJsonFile, "--cache="); ok && len(os.Args) >= 3 {
		cacheFile = cf
		sourcesJsonFile = os.Args[2]
	}
	if err := loadCacheFromFile(); err != nil {
		panic(err)
	}

	stagingTemplate := os.Getenv("BASHBREW_STAGING_TEMPLATE") // "oisupport/staging-ARCH:BUILD"
	if !strings.Contains(stagingTemplate, "BUILD") {
		panic("invalid BASHBREW_STAGING_TEMPLATE (missing BUILD)")
	}

	type out struct {
		buildId string
		json    []byte
	}
	outs := make(chan chan out, concurrency) // we want the end result to be "in order", so we have a channel of channels of outputs so each output can be generated async (and write to the "inner" channel) and the outer channel stays in the input order

	go func() {
		// Go does not have ordered maps *and* is complicated to read an object, make a tiny modification, write it back out (without modelling the entire schema), so we'll let a single invocation of jq solve both problems (munging the documents in the way we expect *and* giving us an in-order stream)
		jq := exec.Command("jq", "-c", ".[] | (.arches | to_entries[]) as $arch | .arches = { ($arch.key): $arch.value }", sourcesJsonFile)
		jq.Stderr = os.Stderr

		stdout, err := jq.StdoutPipe()
		if err != nil {
			panic(err)
		}
		if err := jq.Start(); err != nil {
			panic(err)
		}

		sourceArchResolved := map[string](func() *ocispec.Index){}
		sourceArchResolvedMutex := sync.RWMutex{}

		decoder := json.NewDecoder(stdout)
		for decoder.More() {
			var build MetaBuild

			if err := decoder.Decode(&build.Source); err == io.EOF {
				break
			} else if err != nil {
				panic(err)
			}

			var source MetaSource
			if err := json.Unmarshal(build.Source, &source); err != nil {
				panic(err)
			}

			build.Build.SourceID = source.SourceID

			if len(source.Arches) != 1 {
				panic("unexpected arches length: " + string(build.Source))
			}
			for build.Build.Arch = range source.Arches {
				// I really hate Go.
				// (just doing a lookup of the only key in my map into a variable)
			}

			outChan := make(chan out, 1)
			outs <- outChan

			sourceArchResolvedFunc := sync.OnceValue(func() *ocispec.Index {
				for _, from := range source.Arches[build.Build.Arch].Parents.Keys() {
					if from == "scratch" {
						continue
					}
					var resolved *ocispec.Index
					parent := source.Arches[build.Build.Arch].Parents.Get(from)
					if parent.SourceID != nil {
						sourceArchResolvedMutex.RLock()
						resolvedFunc, ok := sourceArchResolved[*parent.SourceID+"-"+build.Build.Arch]
						if !ok {
							panic("parent of " + source.SourceID + " on " + build.Build.Arch + " should be " + *parent.SourceID + " but that sourceId is unknown to us!")
						}
						sourceArchResolvedMutex.RUnlock()
						resolved = resolvedFunc()
					} else {
						lookup := from
						if parent.Pin != nil {
							lookup += "@" + *parent.Pin
						}

						resolved, err = resolveArchIndex(ctx, lookup, build.Build.Arch, false)
						if err != nil {
							panic(err)
						}
					}
					if resolved == nil {
						fmt.Fprintf(os.Stderr, "%s (%s) -> not yet! [%s]\n", source.SourceID, source.Tags[0], build.Build.Arch)
						close(outChan)
						return nil
					}
					build.Build.ResolvedParents.Set(from, *resolved)
					build.Build.Parents.Set(from, string(resolved.Manifests[0].Digest))
				}

				// buildId calculation
				buildIDJSON, err := json.Marshal(&build.Build.BuildIDParts)
				if err != nil {
					panic(err)
				}
				buildIDJSON = append(buildIDJSON, byte('\n')) // previous calculation of buildId included a newline in the JSON, so this preserves compatibility
				// TODO if we ever have a bigger "buildId break" event (like adding major base images that force the whole tree to rebuild), we should probably ditch this newline

				build.BuildID = fmt.Sprintf("%x", sha256.Sum256(buildIDJSON))
				fmt.Fprintf(os.Stderr, "%s (%s) -> %s [%s]\n", source.SourceID, source.Tags[0], build.BuildID, build.Build.Arch)

				build.Build.Img = strings.ReplaceAll(strings.ReplaceAll(stagingTemplate, "BUILD", build.BuildID), "ARCH", build.Build.Arch) // "oisupport/staging-amd64:xxxx"

				build.Build.Resolved, err = resolveArchIndex(ctx, build.Build.Img, build.Build.Arch, true)
				if err != nil {
					panic(err)
				}

				json, err := json.Marshal(&build)
				if err != nil {
					panic(err)
				}
				outChan <- out{
					buildId: build.BuildID,
					json:    json,
				}

				return build.Build.Resolved
			})
			sourceArchResolvedMutex.Lock()
			sourceArchResolved[source.SourceID+"-"+build.Build.Arch] = sourceArchResolvedFunc
			sourceArchResolvedMutex.Unlock()
			go sourceArchResolvedFunc()
		}

		if err := stdout.Close(); err != nil {
			panic(err)
		}
		if err := jq.Wait(); err != nil {
			panic(err)
		}

		close(outs)
	}()

	fmt.Print("{")
	first := true
	for outChan := range outs {
		out, ok := <-outChan
		if !ok {
			continue
		}
		if !first {
			fmt.Print(",")
		} else {
			first = false
		}
		fmt.Println()
		buildId, err := json.Marshal(out.buildId)
		if err != nil {
			panic(err)
		}
		fmt.Printf("\t%s: %s", string(buildId), string(out.json))
	}
	fmt.Println()
	fmt.Println("}")

	if err := saveCacheToFile(); err != nil {
		panic(err)
	}
}
