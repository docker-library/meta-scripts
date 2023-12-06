package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	c8derrdefs "github.com/containerd/containerd/errdefs"
	"github.com/docker-library/bashbrew/registry"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"github.com/sirupsen/logrus" // this is used by containerd libraries, so we need to set the default log level for it
)

type MetaSource struct {
	SourceID string   `json:"sourceId"`
	AllTags  []string `json:"allTags"`
	Arches   map[string]struct {
		Parents map[string]struct {
			SourceID *string `json:"sourceId"`
			Pin      *string `json:"pin"`
		}
	}
}

type RemoteResolved struct {
	Ref  string             `json:"ref"`
	Desc ocispec.Descriptor `json:"desc"`
}

type RemoteResolvedFull struct {
	Manifest RemoteResolved  `json:"manifest"`
	Index    *RemoteResolved `json:"index,omitempty"`
}

type BuildIDParts struct {
	SourceID string            `json:"sourceId"`
	Arch     string            `json:"arch"`
	Parents  map[string]string `json:"parents"`
}

type MetaBuild struct {
	BuildID string `json:"buildId"`
	Build   struct {
		Img      string              `json:"img"`
		Resolved *RemoteResolvedFull `json:"resolved"`
		BuildIDParts
		ResolvedParents map[string]RemoteResolvedFull `json:"resolvedParents"`
	} `json:"build"`
	Source json.RawMessage `json:"source"`
}

var (
	// keys are image/tag names
	cacheResolve = map[string]*registry.ResolvedObject{}
	// keys are image/index digests
	cacheResolveArches = map[string]map[string][]registry.ResolvedObject{}
)

func resolveRemoteArch(ctx context.Context, img string, arch string) (*RemoteResolvedFull, error) {
	var (
		r       *registry.ResolvedObject
		rArches map[string][]registry.ResolvedObject
		err     error
		ok      bool
	)
	if r, ok = cacheResolve[img]; !ok {
		r, err = registry.Resolve(context.TODO(), img)
		if c8derrdefs.IsNotFound(err) {
			r = nil
		} else if err != nil {
			return nil, err
		}
		cacheResolve[img] = r
	}
	if r == nil {
		return nil, nil
	}

	if rArches, ok = cacheResolveArches[string(r.Desc.Digest)]; !ok {
		// TODO more efficient lookup of single architecture? (probably doesn't matter much)
		rArches, err = r.Architectures(context.TODO())
		if err != nil {
			return nil, err
		}
		cacheResolveArches[string(r.Desc.Digest)] = rArches
	}
	if _, ok := rArches[arch]; !ok {
		// TODO this should probably be just like a 404, right? (it's effectively a 404, even if it's not literally a 404)
		return nil, fmt.Errorf("%s missing %s arch", img, arch)
	}
	// TODO warn/error on multiple entries for arch? (would mean something like index/manifest list with multiple os.version values for Windows - we avoid this in DOI today, but we don't have any automated *checks* for it, so the current state is a little precarious)

	ref := func(obj *registry.ResolvedObject) string {
		base, _, _ := strings.Cut(obj.ImageRef, "@")
		base = strings.TrimPrefix(base, "docker.io/")
		base = strings.TrimPrefix(base, "library/")
		return base + "@" + string(obj.Desc.Digest)
	}
	resolved := &RemoteResolvedFull{
		Manifest: RemoteResolved{
			Ref:  ref(&rArches[arch][0]),
			Desc: rArches[arch][0].Desc,
		},
	}
	if r.IsImageIndex() {
		resolved.Index = &RemoteResolved{
			Ref:  ref(r),
			Desc: r.Desc,
		}
	}
	return resolved, nil
}

func main() {
	sourcesJsonFile := os.Args[1] // "sources.json"

	stagingTemplate := os.Getenv("BASHBREW_STAGING_TEMPLATE") // "oisupport/staging-ARCH:BUILD"
	if !strings.Contains(stagingTemplate, "BUILD") {
		panic("invalid BASHBREW_STAGING_TEMPLATE (missing BUILD)")
	}

	// containerd uses logrus, but it defaults to "info" (which is a bit leaky where we use containerd)
	logrus.SetLevel(logrus.WarnLevel)

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

	var lastSourceID string // used for making cleaner progress output (coalescing multiple concurrent sources)

	sourceArchResolved := map[string]*RemoteResolvedFull{}

	decoder := json.NewDecoder(stdout)
NextSource:
	for decoder.More() {
		var build MetaBuild
		build.Build.Parents = map[string]string{}
		build.Build.ResolvedParents = map[string]RemoteResolvedFull{}

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

		if lastSourceID != source.SourceID {
			fmt.Fprintf(os.Stderr, "%s (%s):\n", source.SourceID, source.AllTags[0])
			lastSourceID = source.SourceID
		}
		fmt.Fprintf(os.Stderr, " -> %s: ", build.Build.Arch)

		for from, parent := range source.Arches[build.Build.Arch].Parents {
			if from == "scratch" {
				continue
			}
			var resolved *RemoteResolvedFull
			if parent.SourceID != nil {
				resolved = sourceArchResolved[*parent.SourceID+"-"+build.Build.Arch]
			} else {
				lookup := from
				if parent.Pin != nil {
					lookup += "@" + *parent.Pin
				}

				resolved, err = resolveRemoteArch(context.TODO(), lookup, build.Build.Arch)
				if err != nil {
					panic(err)
				}
			}
			if resolved == nil {
				fmt.Fprintf(os.Stderr, "not yet!\n")
				continue NextSource
			}
			build.Build.ResolvedParents[from] = *resolved
			build.Build.Parents[from] = string(resolved.Manifest.Desc.Digest)
		}

		// buildId calculation
		buildIDJSON, err := json.Marshal(&build.Build.BuildIDParts)
		if err != nil {
			panic(err)
		}
		buildIDJSON = append(buildIDJSON, byte('\n')) // previous calculation of buildId included a newline in the JSON, so this preserves compatibility

		build.BuildID = fmt.Sprintf("%x", sha256.Sum256(buildIDJSON))
		fmt.Fprintf(os.Stderr, "%s\n", build.BuildID)

		build.Build.Img = strings.ReplaceAll(strings.ReplaceAll(stagingTemplate, "BUILD", build.BuildID), "ARCH", build.Build.Arch) // "oisupport/staging-amd64:xxxx"

		build.Build.Resolved, err = resolveRemoteArch(context.TODO(), build.Build.Img, build.Build.Arch)
		if err != nil {
			panic(err)
		}
		sourceArchResolved[source.SourceID+"-"+build.Build.Arch] = build.Build.Resolved

		json, err := json.Marshal(&build)
		if err != nil {
			panic(err)
		}
		fmt.Println(string(json))
	}

	if err := stdout.Close(); err != nil {
		panic(err)
	}
	if err := jq.Wait(); err != nil {
		panic(err)
	}
}
