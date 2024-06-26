package registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"

	"cuelabs.dev/go/oci/ociregistry"
	godigest "github.com/opencontainers/go-digest"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

var (
	// if a blob is more than this many bytes, we'll do a pre-flight HEAD request to verify whether we need to even bother pushing it before we do so (65535 is the theoretical maximum size of a single TCP packet, although MTU means it's usually closer to 1448 bytes, but this seemed like a sane place to draw a line to where a second request that might fail is worth our time)
	BlobSizeWorthHEAD = int64(65535)
)

// this makes sure the given manifest (index or image) is available at the provided name (tag or digest), including copying any children (manifests or config+layers) if necessary and able (via the provided child lookup map)
func EnsureManifest(ctx context.Context, ref Reference, manifest json.RawMessage, mediaType string, childRefs map[ociregistry.Digest]Reference) (ociregistry.Descriptor, error) {
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
		ref.Digest = desc.Digest
	}

	if _, ok := childRefs[""]; !ok {
		// empty digest is a "fallback" ref for where missing children might be found (if we don't have one, inject one)
		childRefs[""] = ref
	}

	client, err := Client(ref.Host, nil)
	if err != nil {
		return desc, fmt.Errorf("%s: failed getting client: %w", ref, err)
	}

	// try HEAD request before pushing
	// if it matches, then we can assume child objects exist as well
	headRef := ref
	if headRef.Tag != "" {
		// if this function is called with *both* tag *and* digest, the code below works correctly and pushes by tag and then validates by digest, but this lookup specifically will prefer the digest instead and skip when it shouldn't
		headRef.Digest = ""
	}
	r, err := Lookup(ctx, headRef, &LookupOptions{Head: true})
	if err != nil {
		return desc, fmt.Errorf("%s: failed HEAD: %w", ref, err)
	}
	// TODO if we had some kind of progress interface, this would be a great place for some kind of debug log of head's contents
	if r != nil {
		head := r.Descriptor()
		r.Close()
		if head.Digest == desc.Digest && head.Size == desc.Size {
			return head, nil
		}
	}

	// since we need to potentially retry this call after copying/mounting children, let's wrap it up for ease of use
	pushManifest := func() (ociregistry.Descriptor, error) {
		return client.PushManifest(ctx, ref.Repository, ref.Tag, manifest, mediaType)
	}
	rDesc, err := pushManifest()
	if err != nil {
		var httpErr ociregistry.HTTPError
		if errors.Is(err, ociregistry.ErrManifestBlobUnknown) ||
			errors.Is(err, ociregistry.ErrBlobUnknown) ||
			(errors.As(err, &httpErr) && httpErr.StatusCode() >= 400 && httpErr.StatusCode() <= 499) {
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

			childToRefs := func(child ocispec.Descriptor) (Reference, Reference) {
				childTargetRef := Reference{
					Host:       ref.Host,
					Repository: ref.Repository,
					Digest:     child.Digest,
				}
				childRef, ok := childRefs[child.Digest]
				if !ok {
					childRef = childRefs[""]
				}
				childRef.Tag = ""
				childRef.Digest = child.Digest
				return childRef, childTargetRef
			}

			for _, child := range manifestChildren.Manifests {
				childRef, childTargetRef := childToRefs(child)
				r, err := Lookup(ctx, childRef, nil)
				if err != nil {
					return desc, fmt.Errorf("%s: manifest lookup failed: %w", childRef, err)
				}
				if r == nil {
					return desc, fmt.Errorf("%s: manifest not found", childRef)
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
				grandchildRefs := maps.Clone(childRefs)
				grandchildRefs[""] = childRef // make the child's ref explicitly the "fallback" ref for any of its children
				if _, err := EnsureManifest(ctx, childTargetRef, b, child.MediaType, grandchildRefs); err != nil {
					return desc, fmt.Errorf("%s: EnsureManifest failed: %w", ref, err)
				}
				// TODO validate descriptor from EnsureManifest? (at the very least, Digest and Size)
			}

			var childBlobs []ocispec.Descriptor
			if manifestChildren.Config != nil {
				childBlobs = append(childBlobs, *manifestChildren.Config)
			}
			childBlobs = append(childBlobs, manifestChildren.Layers...)
			for _, child := range childBlobs {
				childRef, childTargetRef := childToRefs(child)
				// TODO if blob sets URLs, don't bother (foreign layer) -- maybe check for those MediaTypes explicitly? (not a high priority as they're no longer used and officially discouraged/deprecated; would only matter if Tianon wants to use this for "hell/win" too 👀)
				if _, err := CopyBlob(ctx, childRef, childTargetRef); err != nil {
					return desc, fmt.Errorf("%s: CopyBlob(%s) failed: %w", childTargetRef, childRef, err)
				}
				// TODO validate CopyBlob returned descriptor? (at the very least, Digest and Size)
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

// this copies a manifest (index or image) and all child objects (manifests or config+layers) from one name to another
func CopyManifest(ctx context.Context, srcRef, dstRef Reference, childRefs map[ociregistry.Digest]Reference) (ociregistry.Descriptor, error) {
	var desc ociregistry.Descriptor

	// wouldn't it be nice if MountBlob for manifests was a thing? 🥺
	r, err := Lookup(ctx, srcRef, nil)
	if err != nil {
		return desc, fmt.Errorf("%s: lookup failed: %w", srcRef, err)
	}
	if r == nil {
		return desc, fmt.Errorf("%s: manifest not found", srcRef)
	}
	defer r.Close()
	desc = r.Descriptor()

	manifest, err := io.ReadAll(r)
	if err != nil {
		return desc, fmt.Errorf("%s: reading manifest failed: %w", srcRef, err)
	}

	if _, ok := childRefs[""]; !ok {
		// if we don't have a fallback, set it to src
		childRefs[""] = srcRef
	}

	return EnsureManifest(ctx, dstRef, manifest, desc.MediaType, childRefs)
}

// this takes an [io.Reader] of content and makes sure it is available as a blob in the given repository+digest (if larger than [BlobSizeWorthHEAD], this might return without consuming any of the provided [io.Reader])
func EnsureBlob(ctx context.Context, ref Reference, size int64, content io.Reader) (ociregistry.Descriptor, error) {
	desc := ociregistry.Descriptor{
		Digest: ref.Digest,
		Size:   size,
	}

	if ref.Digest == "" {
		return desc, fmt.Errorf("%s: blobs must be pushed by digest", ref)
	}
	if ref.Tag != "" {
		return desc, fmt.Errorf("%s: blobs cannot have tags", ref)
	}

	if desc.Size > BlobSizeWorthHEAD {
		r, err := Lookup(ctx, ref, &LookupOptions{Type: LookupTypeBlob, Head: true})
		if err != nil {
			return desc, fmt.Errorf("%s: failed HEAD: %w", ref, err)
		}
		// TODO if we had some kind of progress interface, this would be a great place for some kind of debug log of head's contents
		if r != nil {
			head := r.Descriptor()
			r.Close()
			if head.Digest == desc.Digest && head.Size == desc.Size {
				return head, nil
			}
		}
	}

	client, err := Client(ref.Host, nil)
	if err != nil {
		return desc, fmt.Errorf("%s: error getting Client: %w", ref, err)
	}

	return client.PushBlob(ctx, ref.Repository, desc, content)
}

// this copies a blob from one repository to another
func CopyBlob(ctx context.Context, srcRef, dstRef Reference) (ociregistry.Descriptor, error) {
	var desc ociregistry.Descriptor

	if srcRef.Digest == "" {
		return desc, fmt.Errorf("%s: missing digest (cannot copy blob without digest)", srcRef)
	} else if !(dstRef.Digest == "" || dstRef.Digest == srcRef.Digest) {
		return desc, fmt.Errorf("%s: digest mismatch in copy: %s", dstRef, srcRef)
	} else {
		dstRef.Digest = srcRef.Digest
	}
	if srcRef.Tag != "" {
		return desc, fmt.Errorf("%s: blobs cannot have tags", srcRef)
	} else if dstRef.Tag != "" {
		return desc, fmt.Errorf("%s: blobs cannot have tags", dstRef)
	}

	if srcRef.Host == dstRef.Host {
		client, err := Client(srcRef.Host, nil)
		if err != nil {
			return desc, fmt.Errorf("%s: error getting Client: %w", srcRef, err)
		}
		return client.MountBlob(ctx, srcRef.Repository, dstRef.Repository, srcRef.Digest)
	}

	// TODO Push/Reader progress / progresswriter concerns again 😭

	r, err := Lookup(ctx, srcRef, &LookupOptions{Type: LookupTypeBlob})
	if err != nil {
		return desc, fmt.Errorf("%s: blob lookup failed: %w", srcRef, err)
	}
	if r == nil {
		return desc, fmt.Errorf("%s: blob not found", srcRef)
	}
	defer r.Close()
	desc = r.Descriptor()

	if dstRef.Digest != desc.Digest {
		return desc, fmt.Errorf("%s: registry digest mismatch: %s (%s)", dstRef, desc.Digest, srcRef)
	}

	if _, err := EnsureBlob(ctx, dstRef, desc.Size, r); err != nil {
		return desc, fmt.Errorf("%s: EnsureBlob(%s) failed: %w", dstRef, srcRef, err)
	}
	// TODO validate returned descriptor? (at least digest/size)

	if err := r.Close(); err != nil {
		return desc, fmt.Errorf("%s: Close of GetBlob(%s) failed: %w", dstRef, srcRef, err)
	}

	return desc, nil
}
