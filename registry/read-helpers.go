package registry

import (
	"encoding/json"
	"fmt"
	"io"
	"unicode"

	"cuelabs.dev/go/oci/ociregistry"
)

// reads a JSON object from the given [ociregistry.BlobReader], but also validating the [ociregistry.Descriptor.Digest] and [ociregistry.Descriptor.Size] from [ociregistry.BlobReader.Descriptor] (and returning appropriate errors)
//
// TODO split this up for reading raw objects ~safely too? (https://github.com/docker-library/bashbrew/commit/0f3f0042d0da95affb75e250a77100b4ae58832f) -- maybe even a separate `io.Reader`+`Descriptor` interface that doesn't require a BlobReader specifically?
func readJSONHelper(r ociregistry.BlobReader, v interface{}) error {
	desc := r.Descriptor()

	// prevent go-digest panics later
	if err := desc.Digest.Validate(); err != nil {
		return err
	}

	// TODO if desc.Data != nil and len() == desc.Size, we should probably check/use that? 👀

	// make sure we can't possibly read (much) more than we're supposed to
	limited := &io.LimitedReader{
		R: r,
		N: desc.Size + 1, // +1 to allow us to detect if we read too much (see verification below)
	}

	// copy all read data into the digest verifier so we can validate afterwards
	verifier := desc.Digest.Verifier()
	tee := io.TeeReader(limited, verifier)

	// decode directly! (mostly avoids double memory hit for big objects)
	// (TODO protect against malicious objects somehow?)
	if err := json.NewDecoder(tee).Decode(v); err != nil {
		return err
	}

	// read anything leftover ...
	bs, err := io.ReadAll(tee)
	if err != nil {
		return err
	}
	// ... and make sure it was just whitespace, if anything
	for _, b := range bs {
		if !unicode.IsSpace(rune(b)) {
			return fmt.Errorf("unexpected non-whitespace at the end of %q: %+v\n", string(desc.Digest), rune(b))
		}
	}

	// now that we know we've read everything, we're safe to close the original reader
	if err := r.Close(); err != nil {
		return err
	}

	// after reading *everything*, we should have exactly one byte left in our LimitedReader (anything else is an error)
	if limited.N < 1 {
		return fmt.Errorf("size of %q is bigger than it should be (%d)", string(desc.Digest), desc.Size)
	} else if limited.N > 1 {
		return fmt.Errorf("size of %q is %d bytes smaller than it should be (%d)", string(desc.Digest), limited.N-1, desc.Size)
	}

	// and finally, let's verify our checksum
	if !verifier.Verified() {
		return fmt.Errorf("digest of %q not correct", string(desc.Digest))
	}

	return nil
}
