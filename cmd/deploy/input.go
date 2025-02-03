package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"maps"

	"github.com/docker-library/meta-scripts/registry"

	"cuelabs.dev/go/oci/ociregistry"
	godigest "github.com/opencontainers/go-digest"
)

// see TestNormalizeInput for example use cases / usage (pushing images/indexes, pushing blobs, copying images/indexes/blobs)

// TODO should this be normalized to registry.LookupType?  should that be renamed to registry.ObjectType or something more generic?
type deployType string

const (
	typeManifest deployType = "manifest"
	typeBlob     deployType = "blob"
)

type inputRaw struct {
	// which type of thing we're pushing ("manifest" or "blob")
	Type deployType `json:"type"`

	// where to push the thing ("jsmith/example:latest", "jsmith/example@sha256:xxx", etc)
	Refs []string `json:"refs"`

	// a lookup table for where to find any children, if necessary (for example, pushing an index and need to be able to query/copy the child manifests, pushing a manifest and needing to copy blobs, etc), or the object we want to copy
	Lookup map[string]string `json:"lookup,omitempty"`

	// the data to push; if this is a JSON string, it is assumed to be a "raw" base64-encoded byte stream that should be pushed as-is, otherwise it'll be formatted and pushed as JSON (great for index, manifest, config, etc)
	Data json.RawMessage `json:"data,omitempty"`
}

// effectively, this is [inputRaw] but normalized in many ways (with inferred data like where to copy data from being explicit instead)
type inputNormalized struct {
	Type   deployType                                `json:"type"`
	Refs   []registry.Reference                      `json:"refs"`
	Lookup map[ociregistry.Digest]registry.Reference `json:"lookup,omitempty"`

	// Data and CopyFrom are mutually exclusive
	Data     []byte              `json:"data,omitempty"`
	CopyFrom *registry.Reference `json:"copyFrom,omitempty"`

	// if CopyFrom is nil and Type is manifest, this will be set (used by "do")
	MediaType string `json:"mediaType,omitempty"`
}

func (normal inputNormalized) clone() inputNormalized {
	// normal.Lookup is the only thing we have concurrency issues with, so it's the only thing we'll explicitly clone 😇
	normal.Lookup = maps.Clone(normal.Lookup)
	return normal
}

func normalizeInputRefs(deployType deployType, rawRefs []string) ([]registry.Reference, ociregistry.Digest, error) {
	refs := make([]registry.Reference, len(rawRefs))
	var commonDigest ociregistry.Digest // if any ref has a digest, they all have to have the same digest (and our data has to match)
	for i, refString := range rawRefs {
		ref, err := registry.ParseRef(refString)
		if err != nil {
			return nil, "", fmt.Errorf("%s: failed to parse ref: %w", refString, err)
		}

		if ref.Digest != "" {
			if commonDigest == "" {
				commonDigest = ref.Digest
			} else if ref.Digest != commonDigest {
				return nil, "", fmt.Errorf("refs digest mismatch in %s: %s", ref, commonDigest)
			}
		}

		if deployType == typeBlob && ref.Tag != "" {
			return nil, "", fmt.Errorf("cannot push blobs to a tag: %s", ref)
		}

		refs[i] = ref
	}

	return refs, commonDigest, nil
}

func normalizeInputLookup(rawLookup map[string]string) (map[ociregistry.Digest]registry.Reference, *ociregistry.Digest, error) {
	lookup := make(map[ociregistry.Digest]registry.Reference, len(rawLookup))
	var digest ociregistry.Digest // if we store this out here, we can abuse it later to get the "last" lookup digest (for getting the single key in the case of len(lookup) == 1 without a new loop)
	for d, refString := range rawLookup {
		digest = ociregistry.Digest(d)
		if digest != "" {
			// normal.Lookup[""] is a special case for fallback (where to look for any child object that isn't explicitly referenced)
			if err := digest.Validate(); err != nil {
				return nil, nil, fmt.Errorf("lookup key %q invalid: %w", digest, err)
			}
		}
		if ref, err := registry.ParseRef(refString); err != nil {
			return nil, nil, fmt.Errorf("failed to parse lookup ref %q: %v", refString, err)
		} else {
			if ref.Tag != "" && digest != "" {
				//return normal, fmt.Errorf("%s: tag on by-digest lookup ref makes no sense: %s (%s)", debugId, ref, d)
			}

			if ref.Digest == "" && digest != "" {
				ref.Digest = digest
			}
			if digest != "" && ref.Digest != digest {
				return nil, nil, fmt.Errorf("digest on lookup ref should either be omitted or match key: %s vs %s", ref, d)
			}

			lookup[digest] = ref
		}
	}

	// see notes on "digest" definition
	if len(lookup) != 1 {
		return lookup, nil, nil
	}
	if digest == "" && (lookup[""].Digest == "" && lookup[""].Tag == "") {
		// if it was a fallback, it needs at least Tag or Digest (or our refs need Digest, so we can infer)
		return lookup, nil, nil
	}
	return lookup, &digest, nil
}

func NormalizeInput(raw inputRaw) (inputNormalized, error) {
	var normal inputNormalized

	switch raw.Type {
	case "":
		// TODO is there one of the two types that I might push by hand more often than the other that could be the default when this is unspecified?
		return normal, fmt.Errorf("missing type")

	case typeManifest, typeBlob:
		normal.Type = raw.Type

	default:
		return normal, fmt.Errorf("unknown type: %s", raw.Type)
	}

	if raw.Refs == nil {
		return normal, fmt.Errorf("missing refs entirely (JSON input glitch?)")
	}
	if len(raw.Refs) == 0 {
		return normal, fmt.Errorf("zero refs specified for pushing (need at least one)")
	}
	var (
		refsDigest ociregistry.Digest
		err        error
	)
	normal.Refs, refsDigest, err = normalizeInputRefs(normal.Type, raw.Refs)
	if err != nil {
		return normal, err
	}

	debugId := normal.Refs[0] // used for annotating errors from here out
	var lookupDigest *ociregistry.Digest
	normal.Lookup, lookupDigest, err = normalizeInputLookup(raw.Lookup)
	if err != nil {
		return normal, fmt.Errorf("%s: %w", debugId, err)
	}

	if raw.Data == nil || bytes.Equal(raw.Data, []byte("null")) {
		// if we have no Data, let's see if we have enough information to infer an object to copy
		if lookupRef, ok := normal.Lookup[refsDigest]; refsDigest != "" && ok {
			// if any of our Refs had a digest, *and* we have a way to Lookup that digest, that's the one
			lookupDigest = &refsDigest
			normal.CopyFrom = &lookupRef
		} else if lookupDigest != nil {
			// if we only had one Lookup entry, that's the one
			lookupRef := normal.Lookup[*lookupDigest]
			normal.CopyFrom = &lookupRef
		} else if lookupRef, ok := normal.Lookup[""]; refsDigest != "" && ok {
			lookupDigest = &refsDigest
			lookupRef.Digest = refsDigest
			normal.CopyFrom = &lookupRef
		} else {
			// if Lookup has only a single entry, that's the one (but that's our last chance for inferring intent)
			return normal, fmt.Errorf("%s: missing data (and lookup is not a single item or fallback with digest or tag)", debugId)
			// TODO *technically* it would be fair to have lookup have two items if one of them is the fallback reference, but it doesn't really make much sense to copy an object from one namespace, but to get all its children from somewhere else
		}

		if *lookupDigest == "" && normal.CopyFrom.Digest != "" {
			lookupDigest = &normal.CopyFrom.Digest
		}

		if _, ok := normal.Lookup[""]; !ok {
			// if we don't have a fallback, add this ref as the fallback
			normal.Lookup[""] = *normal.CopyFrom
		}

		if refsDigest == "" {
			refsDigest = *lookupDigest
		} else if *lookupDigest != "" && refsDigest != *lookupDigest {
			return normal, fmt.Errorf("%s: copy-by-digest mismatch: %s vs %s", debugId, refsDigest, normal.CopyFrom)
		}
	} else {
		if len(raw.Data) > 0 && raw.Data[0] == '"' {
			// must be a "raw" base64-string blob, let's decode it so we're ready to push it
			if err := json.Unmarshal(raw.Data, &normal.Data); err != nil {
				return normal, fmt.Errorf("%s: failed to parse base64 data blob: %w", debugId, err)
			}
		} else {
			// otherwise it must be JSON input
			normal.Data = raw.Data
			if bytes.ContainsRune(normal.Data, '\n') && normal.Data[len(normal.Data)-1] != '\n' {
				// if it has any newlines in it, we can assume it was pretty-printed and we should ensure it has a trailing newline too (reading json.RawMessage understandably leaves off trailing whitespace)
				normal.Data = append(normal.Data, '\n')
			}
		}

		dataDigest := godigest.FromBytes(normal.Data)
		if refsDigest == "" {
			refsDigest = dataDigest
		} else if refsDigest != dataDigest {
			return normal, fmt.Errorf("%s: push-by-digest implied by refs, but data does not match: %s vs %s", debugId, refsDigest, dataDigest)
		}
	}

	// we already validated above that any ref with a digest was the same as refsDigest, so here we can just blindly clobber them all
	for i := range normal.Refs {
		normal.Refs[i].Digest = refsDigest
	}

	// if we have a digest and we're performing a copy, the tag we're copying *from* is no longer relevant information
	if refsDigest != "" && normal.CopyFrom != nil {
		normal.CopyFrom.Tag = ""
	}

	// explicitly clear tag and digest from lookup entries (now that we've inferred any "CopyFrom" out of them, they no longer have any meaning)
	for d, ref := range normal.Lookup {
		if d == "" && refsDigest == "" && ref.Tag != "" && normal.CopyFrom != nil && ref.Tag == normal.CopyFrom.Tag {
			// let the "fallback" ref keep a tag when it's the tag we're copying and there's no known digest (this allows our normalized objects to still be completely valid "raw" inputs)
			continue
		}
		ref.Tag = ""
		ref.Digest = ""
		normal.Lookup[d] = ref
	}

	// front-load some validation / data extraction for "normal.do" to work
	switch normal.Type {
	case typeManifest:
		if normal.CopyFrom == nil {
			// instead of asking for mediaType explicitly, we'll enforce that any manifest we push *must* specify mediaType in the manifest itself (which then is *not* a restriction which applies to any children we copy); see https://github.com/opencontainers/distribution-spec/security/advisories/GHSA-mc8v-mgrf-8f4m and https://github.com/opencontainers/image-spec/security/advisories/GHSA-77vh-xpmg-72qh
			var mediaTypeHaver struct {
				// https://github.com/opencontainers/image-spec/blob/v1.1.0/specs-go/v1/index.go#L25
				// https://github.com/opencontainers/image-spec/blob/v1.1.0/specs-go/v1/manifest.go#L24
				MediaType string `json:"mediaType"`
			}
			if err := json.Unmarshal(normal.Data, &mediaTypeHaver); err != nil {
				return normal, fmt.Errorf("%s: failed to parse %s data for mediaType: %w", debugId, normal.Type, err)
			}
			if mediaTypeHaver.MediaType == "" {
				// we could just leave this blank and leave it up to the registry to reject instead: https://github.com/opencontainers/distribution-spec/blob/v1.1.0/spec.md#push:~:text=Clients%20SHOULD%20set,the%20mediaType%20field.
				// however, PushManifest expects mediaType: https://github.com/cue-labs/oci/blob/f3720d0e1bec6540a9b3c8783af010f51ad5cc95/ociregistry/ociclient/writer.go#L53
				// and our logic for pushing children needs to know the mediaType (see the GHSAs referenced above)
				return normal, fmt.Errorf("%s: pushing manifest but missing 'mediaType'", debugId)
			}
			normal.MediaType = mediaTypeHaver.MediaType
		}

	case typeBlob:
		if normal.CopyFrom != nil && normal.CopyFrom.Digest == "" {
			return normal, fmt.Errorf("%s: blobs are always by-digest, and thus need a digest: %s", debugId, normal.CopyFrom)
		}

	default:
		panic("unknown type: " + string(normal.Type))
		// panic instead of error because this should've already been handled/normalized above (so this is a coding error, not a runtime error)
	}

	return normal, nil
}

// WARNING: many of these codepaths will end up writing to "normal.Lookup", which because it's a map is passed by reference, so this method is *not* safe for concurrent invocation on a single "normal" object!  see "normal.clone" (above)
func (normal inputNormalized) do(ctx context.Context, dstRef registry.Reference) (ociregistry.Descriptor, error) {
	switch normal.Type {
	case typeManifest:
		if normal.CopyFrom == nil {
			// TODO panic on bad data, like MediaType being empty?
			return registry.EnsureManifest(ctx, dstRef, normal.Data, normal.MediaType, normal.Lookup)
		} else {
			return registry.CopyManifest(ctx, *normal.CopyFrom, dstRef, normal.Lookup)
		}

	case typeBlob:
		if normal.CopyFrom == nil {
			return registry.EnsureBlob(ctx, dstRef, int64(len(normal.Data)), bytes.NewReader(normal.Data))
		} else {
			return registry.CopyBlob(ctx, *normal.CopyFrom, dstRef)
		}

	default:
		panic("unknown type: " + string(normal.Type))
		// panic instead of error because this should've already been handled/normalized above (so this is a coding error, not a runtime error)
	}
}

// "do", but doesn't mutate state at all (just tells us whether "do" would've done anything)
func (normal inputNormalized) dryRun(ctx context.Context, dstRef registry.Reference) (bool, error) {
	targetDigest := dstRef.Digest
	var lookupType registry.LookupType
	switch normal.Type {
	case typeManifest:
		lookupType = registry.LookupTypeManifest
		if targetDigest == "" {
			// if we don't have a digest here, it must be because we're copying from tag to tag, so we'll just assume normal.CopyFrom is non-nil and let the runtime panic for us if the normalization above doesn't have our back
			r, err := registry.Lookup(ctx, *normal.CopyFrom, &registry.LookupOptions{
				Type: lookupType,
				Head: true,
			})
			if err != nil {
				return true, err
			}
			if r == nil {
				return true, fmt.Errorf("%s: manifest-to-copy (%s) is 404", dstRef.String(), normal.CopyFrom.String())
			}
			targetDigest = r.Descriptor().Digest
			r.Close()
			if targetDigest == "" {
				return true, fmt.Errorf("%s: manifest-to-copy (%s) is missing digest!", dstRef.String(), normal.CopyFrom.String())
			}
			if dstRef.Tag == "" {
				// if we don't have an explicit destination tag, this is considered a request to copy-manifest-from-tag-but-push-by-digest, which is weird, but valid, so we need to copy up that digest into what we look for on the destination side
				dstRef.Digest = targetDigest
			}
		}
	case typeBlob:
		lookupType = registry.LookupTypeBlob
		if targetDigest == "" {
			// see validation above in normalization
			panic("blob ref missing digest, this should never happen: " + dstRef.String())
		}
	default:
		panic("unknown type: " + string(normal.Type))
		// panic instead of error because this should've already been handled/normalized above (so this is a coding error, not a runtime error)
	}

	r, err := registry.Lookup(ctx, dstRef, &registry.LookupOptions{
		Type: lookupType,
		Head: true,
	})
	if err != nil {
		return true, err
	}
	if r == nil {
		// 404!
		return true, nil
	}
	dstDigest := r.Descriptor().Digest
	r.Close()
	return targetDigest != dstDigest, nil
}
