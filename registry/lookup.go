package registry

import (
	"context"
	"errors"
	"fmt"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ocimem"
)

// see `LookupType*` consts for possible values for this type
type LookupType string

const (
	LookupTypeManifest LookupType = "manifest"
	LookupTypeBlob     LookupType = "blob"
)

type LookupOptions struct {
	// unspecified implies [LookupTypeManifest]
	Type LookupType

	// whether or not to do a HEAD instead of a GET (will still return an [ociregistry.BlobReader], but with an empty body / zero bytes)
	Head bool

	// TODO allow providing a Descriptor here for more validation and/or for automatic usage of any usable/valid Data field?
	// TODO (also, if the provided Reference includes a Digest, we should probably validate it? are there cases where we don't want to / shouldn't?)
}

// a wrapper around [ociregistry.Interface.GetManifest] (and `GetTag`, `GetBlob`, and the `Resolve*` versions of the above) that accepts a [Reference] and always returns a [ociregistry.BlobReader] (in the case of a HEAD request, it will be a zero-length reader with just a valid descriptor)
func Lookup(ctx context.Context, ref Reference, opts *LookupOptions) (ociregistry.BlobReader, error) {
	client, err := Client(ref.Host, nil)
	if err != nil {
		return nil, fmt.Errorf("%s: failed getting client: %w", ref, err)
	}

	var o LookupOptions
	if opts != nil {
		o = *opts
	}

	var (
		r    ociregistry.BlobReader
		desc ociregistry.Descriptor
	)
	switch o.Type {
	case LookupTypeManifest, "":
		if ref.Digest != "" {
			if o.Head {
				desc, err = client.ResolveManifest(ctx, ref.Repository, ref.Digest)
			} else {
				r, err = client.GetManifest(ctx, ref.Repository, ref.Digest)
			}
		} else {
			tag := ref.Tag
			if tag == "" {
				tag = "latest"
			}
			if o.Head {
				desc, err = client.ResolveTag(ctx, ref.Repository, tag)
			} else {
				r, err = client.GetTag(ctx, ref.Repository, tag)
			}
		}

	case LookupTypeBlob:
		// TODO error if Digest == "" ? (ociclient already does for us, so we can probably just pass it through here without much worry)
		if o.Head {
			desc, err = client.ResolveBlob(ctx, ref.Repository, ref.Digest)
		} else {
			r, err = client.GetBlob(ctx, ref.Repository, ref.Digest)
		}

	default:
		return nil, fmt.Errorf("unknown LookupType: %q", o.Type)
	}

	// normalize 404 and 404-like to nil return (so it's easier to detect)
	if err != nil {
		if errors.Is(err, ociregistry.ErrBlobUnknown) ||
			errors.Is(err, ociregistry.ErrManifestUnknown) ||
			errors.Is(err, ociregistry.ErrNameUnknown) {
			// obvious 404 cases
			return nil, nil
		}
		var httpErr ociregistry.HTTPError
		if errors.As(err, &httpErr) && (httpErr.StatusCode() == 404 ||
			// 401 often means "repository not found" (due to the nature of public/private mixing on Hub and the fact that ociauth definitely handled any possible authentication for us, so if we're still getting 401 it's unavoidable and might as well be 404, and 403 because getting 401 is actually a server bug that ociclient/ociauth works around for us in https://github.com/cue-labs/oci/commit/7eb5fc60a0e025038cd64d7f5df0a461136d5e9b)
			httpErr.StatusCode() == 401 || httpErr.StatusCode() == 403) {
			return nil, nil
		}
		return r, err
	}

	if o.Head {
		r = ocimem.NewBytesReader(nil, desc)
	}

	return r, err
}
