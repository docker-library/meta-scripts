package registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ociref"
	godigest "github.com/opencontainers/go-digest"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

type PushIndexOp struct {
	// list of tags we want to push to
	Tags []string `json:"tags"`

	// lookup table of digests to where we can find them (used if we need to push / blob mount children of the index to push it successfully)
	Manifests map[ociregistry.Digest]string `json:"manifests"`

	// the actual index object; likely provided/unmarshalled as a second object for better raw whitespace (otherwise you'll get weird indentation in your object unless you compress-print everything)
	Index json.RawMessage `json:"index",omitempty`
}

func PushIndex(ctx context.Context, meta PushIndexOp) (ociregistry.Descriptor, error) {
	var desc ociregistry.Descriptor

	if meta.Tags == nil {
		return desc, fmt.Errorf("missing tags entirely (JSON input glitch?)")
	}
	if len(meta.Tags) == 0 {
		return desc, fmt.Errorf("zero tags specified for pushing (need at least one)")
	}

	var index ocispec.Index
	if err := json.Unmarshal(meta.Index, &index); err != nil {
		return desc, fmt.Errorf("%s: failed to parse index: %w", meta.Tags[0], err)
	}

	if index.SchemaVersion != 2 {
		return desc, fmt.Errorf("%s: unsupported index schemaVersion: %d", meta.Tags[0], index.SchemaVersion)
	}
	switch index.MediaType {
	case ocispec.MediaTypeImageIndex, mediaTypeDockerManifestList:
		// all good, do nothing!
	default:
		return desc, fmt.Errorf("%s: unsupported index mediaType: %q", meta.Tags[0], index.MediaType)
	}
	manifestRefs := map[ociregistry.Digest]ociref.Reference{}
	for _, manifest := range index.Manifests {
		if manifestRefString, ok := meta.Manifests[manifest.Digest]; !ok {
			return desc, fmt.Errorf("%s: index vs meta manifests gap: %s", meta.Tags[0], manifest.Digest)
		} else if manifestRef, err := ParseRefNormalized(manifestRefString); err != nil {
			return desc, fmt.Errorf("%s: failed to parse: %w", manifestRef, err)
		} else if manifestRef.Digest != manifest.Digest {
			return desc, fmt.Errorf("%s: meta manifests object reference %s have digest of %s", meta.Tags[0], manifestRefString, manifest.Digest)
		} else {
			manifestRefs[manifest.Digest] = manifestRef
		}
	}

	desc.MediaType = index.MediaType
	desc.Digest = godigest.FromBytes(meta.Index)
	desc.Size = int64(len(meta.Index))

	for _, tag := range meta.Tags {
		ref, err := ParseRefNormalized(tag)
		if err != nil {
			return desc, fmt.Errorf("%s: error parsing: %w", tag, err)
		}
		if ref.Digest != "" {
			if ref.Digest != desc.Digest {
				return desc, fmt.Errorf("%s: digest mismatch: %s", tag, desc.Digest)
			}
		} else if ref.Tag == "" {
			return desc, fmt.Errorf("%s: missing tag (and we want to be explicit)", tag)
		}

		//fmt.Printf("Pushing %s to %s ...\n", digest, ref) // TODO some kind of "progresswriter" interface?? 😭 (everything sucks and we're all gonna die eventually)

		rDesc, err := ensureManifest(ctx, ref, meta.Index, index.MediaType, manifestRefs)
		if err != nil {
			return desc, err // TODO annotate
		}
		// TODO validate MediaType and Size too? 🤷
		if rDesc.Digest != desc.Digest {
			return desc, fmt.Errorf("%s: pushed digest from registry (%s) does not match expected digest (%s)", tag, rDesc.Digest, desc.Digest)
		}
	}

	return desc, nil
}

func ensureManifest(ctx context.Context, ref ociref.Reference, manifest json.RawMessage, mediaType string, childRefs map[ociregistry.Digest]ociref.Reference) (ociregistry.Descriptor, error) {
	desc := ociregistry.Descriptor{
		MediaType: mediaType,
		Digest:    godigest.FromBytes(manifest),
		Size:      int64(len(manifest)),
	}
	if ref.Digest != "" {
		if ref.Digest != desc.Digest {
			return desc, fmt.Errorf("%s: digest mismatch: %s", ref, desc.Digest)
		}
	} else if ref.Tag == "" {
		return desc, fmt.Errorf("%s: missing tag (and we want to be explicit)", ref)
	}

	switch mediaType {
	case ocispec.MediaTypeImageManifest, mediaTypeDockerImageManifest:
		// all good, do nothing!
	case ocispec.MediaTypeImageIndex, mediaTypeDockerManifestList:
		// all good, do nothing!
	default:
		return desc, fmt.Errorf("%s: unsupported manifest mediaType: %q", ref, mediaType)
	}

	client, err := Client(ref.Host, nil)
	if err != nil {
		return desc, fmt.Errorf("%s: failed getting client: %w", ref, err)
	}

	// since we need to potentially retry this call after copying/mounting children, let's wrap it up for ease of use
	pushManifest := func() (ociregistry.Descriptor, error) {
		return client.PushManifest(ctx, ref.Repository, ref.Tag, manifest, mediaType)
	}
	rDesc, err := pushManifest()
	if err != nil {
		// https://github.com/cue-labs/oci/issues/26
		if errors.Is(err, ociregistry.ErrManifestBlobUnknown) ||
			errors.Is(err, ociregistry.ErrBlobUnknown) ||
			strings.HasPrefix(err.Error(), "400 ") {
			// this probably means we need to push some child manifests and/or mount missing blobs (and then retry the manifest push)
			var manifestChildren struct {
				// *technically* this should be two separate structs chosen based on mediaType (https://github.com/opencontainers/distribution-spec/security/advisories/GHSA-mc8v-mgrf-8f4m), but that makes the code a lot more annoying when we're just collecting a list of potential children we need to copy over for the parent object to push successfully

				// intentional subset of https://github.com/opencontainers/image-spec/blob/v1.1.0/specs-go/v1/index.go#L21 to minimize parsing
				Manifests []ocispec.Descriptor `json:"manifests"`

				// intentional subset of https://github.com/opencontainers/image-spec/blob/v1.1.0/specs-go/v1/manifest.go#L20 to minimize parsing
				Config *ocispec.Descriptor  `json:"config"` // have to turn this into a pointer so we can recognize when it's not set easier / more correctly
				Layers []ocispec.Descriptor `json:"layers"`
			}
			if err := json.Unmarshal(manifest, &manifestChildren); err != nil {
				return desc, fmt.Errorf("%s: failed parsing manifest JSON: %w", ref, err)
			}
			var children []ocispec.Descriptor
			children = append(children, manifestChildren.Manifests...)
			if manifestChildren.Config != nil {
				children = append(children, *manifestChildren.Config)
			}
			children = append(children, manifestChildren.Layers...)
			for _, child := range children {
				childTargetRef := ociref.Reference{
					Host:       ref.Host,
					Repository: ref.Repository,
					Digest:     child.Digest,
				}
				childRef, ok := childRefs[child.Digest]
				if !ok {
					// allow empty digest to specify a "fallback" ref for where missing children might be found
					if childRef, ok = childRefs[""]; !ok {
						return desc, fmt.Errorf("%s: missing source reference for missing child: %s", ref, child.Digest)
					}
				}
				// this isn't *technically* necessary (we could just use "child.Digest" in "GetManifest", "MountBlob", etc below), but being strictly correct makes us feel better (with minimal overhead)
				childRef.Tag = ""
				childRef.Digest = child.Digest

				childClient, err := Client(childRef.Host, nil)
				if err != nil {
					return desc, fmt.Errorf("%s: failed getting (child) client: %w", childRef, err)
				}

				switch child.MediaType {
				case ocispec.MediaTypeImageManifest, mediaTypeDockerImageManifest, ocispec.MediaTypeImageIndex, mediaTypeDockerManifestList:
					r, err := childClient.GetManifest(ctx, childRef.Repository, childRef.Digest)
					if err != nil {
						return desc, fmt.Errorf("%s: GetManifest failed: %w", childRef, err)
					}
					//defer r.Close()
					// TODO validate r.Descriptor ?
					// TODO use readHelperRaw here (maybe a new "readHelperAll" wrapper too?)
					b, err := io.ReadAll(r)
					if err != nil {
						r.Close()
						return desc, fmt.Errorf("%s: ReadAll of GetManifest failed: %w", childRef, err)
					}
					if err := r.Close(); err != nil {
						return desc, fmt.Errorf("%s: Close of GetManifest failed: %w", childRef, err)
					}
					if _, err := ensureManifest(ctx, childTargetRef, b, child.MediaType, map[ociregistry.Digest]ociref.Reference{"": childRef}); err != nil {
						return desc, err // TODO annotate
					}
					// TODO validate ensureManifest returned descriptor?

				default: // if not obviously manifest, assume blob
					// TODO if blob sets URLs, don't bother (foreign layer) -- maybe check for those MediaTypes explicitly? (not a high priority as they're no longer used and officially discouraged/deprecated; would only matter if Tianon wants to use this for "hell/win" too 👀)
					if childRef.Host == childTargetRef.Host {
						if _, err := childClient.MountBlob(ctx, childRef.Repository, childTargetRef.Repository, childRef.Digest); err != nil {
							return desc, fmt.Errorf("%s: MountBlob(%s) failed: %w", childTargetRef, childRef, err)
						}
						// TODO validate MountBlob returned descriptor?
					} else {
						// TODO Push/Reader progress / progresswriter concerns again 😭
						// TODO in this case, streaming the blob back and forth between registries is heavy enough that it's probably worth doing a preflight HEAD check for whether we even need to 👀
						r, err := childClient.GetBlob(ctx, childRef.Repository, childRef.Digest)
						if err != nil {
							return desc, fmt.Errorf("%s: GetBlob failed: %w", childRef, err)
						}
						//r.Close()
						// TODO validate r.Descriptor ? (esp since we trust it enough to pass it forwards verbatim here)
						if _, err := client.PushBlob(ctx, childTargetRef.Repository, r.Descriptor(), r); err != nil {
							r.Close()
							return desc, fmt.Errorf("%s: PushBlob(%s) failed: %w", childTargetRef, childRef, err)
						}
						// TODO validate PushBlob returned descriptor?
						if err := r.Close(); err != nil {
							return desc, fmt.Errorf("%s: Close of PushBlob(%s) failed: %w", childTargetRef, childRef, err)
						}
					}
				}
			}
			rDesc, err = pushManifest()
			if err != nil {
				return desc, fmt.Errorf("%s: PushManifest failed: %w", ref, err)
			}
		} else {
			return desc, fmt.Errorf("%s: error pushing (does not appear to be missing manifest/blob related): %w", ref, err)
		}
	}
	// TODO validate MediaType and Size too? 🤷
	if rDesc.Digest != desc.Digest {
		return desc, fmt.Errorf("%s: pushed digest from registry (%s) does not match expected digest (%s)", ref, rDesc.Digest, desc.Digest)
	}
	return desc, nil
}

// "crane copy" (but only for digested objects, in service of PushIndex)
func ensureObject(ctx context.Context, targetRepo ociref.Reference, mediaType string, ref ociref.Reference) (ociregistry.Descriptor, error) {
	var desc ociregistry.Descriptor

	// make sure we don't accidentally use or apply any value to "Digest" or "Tag" from our "target repo" ref (it's purely for host and repository)
	targetRepo.Digest = ""
	targetRepo.Tag = ""

	// we don't want to do expensive blob copies (yet / for now?) 😅
	if targetRepo.Host != ref.Host {
		return desc, fmt.Errorf("cross-registry copy is currently unsupported (%s <- %s)", targetRepo, ref)
	}

	client, err := Client(targetRepo.Host, nil)
	if err != nil {
		return desc, fmt.Errorf("%s: failed getting (target) client: %w", targetRepo, err)
	}

	switch mediaType {
	case ocispec.MediaTypeImageManifest, mediaTypeDockerImageManifest:
		// TODO
		return desc, fmt.Errorf("TODO")
	case ocispec.MediaTypeImageIndex, mediaTypeDockerManifestList:
		// TODO
		return desc, fmt.Errorf("TODO")
	default:
		// assume it is a blob and we can just mount it accordingly
		return client.MountBlob(ctx, ref.Repository, targetRepo.Repository, ref.Digest)
	}
}
