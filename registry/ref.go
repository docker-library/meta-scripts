package registry

import (
	"strings"

	// thanks, go-digest...
	_ "crypto/sha256"
	_ "crypto/sha512"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ociref"
)

// parse a string ref like `hello-world:latest` directly into a [Reference] object, with Docker Hub canonicalization applied: `docker.io/library/hello-world:latest`
//
// See also [Reference.Normalize] and [ociref.ParseRelative] (which are the underlying implementation details of this method).
func ParseRef(img string) (Reference, error) {
	r, err := ociref.ParseRelative(img)
	if err != nil {
		return Reference{}, err
	}
	ref := Reference(r)
	ref.Normalize()
	return ref, nil
}

// copy ociref.Reference so we can add methods (especially for JSON round-trip, but also Docker-isms like the implied default [Reference.Host] and `library/` prefix for DOI)
type Reference ociref.Reference

// normalize Docker Hub refs like `hello-world:latest`: `docker.io/library/hello-world:latest`
//
// NOTE: this explicitly does *not* normalize Tag to `:latest` because it's useful to be able to parse a reference and know it did not specify either tag or digest (and `if ref.Tag == "" { ref.Tag = "latest" }` is really trivial code outside this for that case)
func (ref *Reference) Normalize() {
	if dockerHubHosts[ref.Host] {
		// normalize Docker Hub host value
		ref.Host = dockerHubCanonical
		// normalize Docker Official Images to library/ prefix
		if !strings.Contains(ref.Repository, "/") {
			ref.Repository = "library/" + ref.Repository
		}
		// add an error return and return an error if we have more than one "/" in Repository?  probably not worth embedding that many "Hub" implementation details this low (since it'll error appropriately on use of such invalid references anyhow)
	}
}

// like [ociref.Reference.String], but with Docker Hub "denormalization" applied (no explicit `docker.io` host, no `library/` prefix for DOI)
func (ref Reference) String() string {
	if ref.Host == dockerHubCanonical {
		ref.Host = ""
		ref.Repository = strings.TrimPrefix(ref.Repository, "library/")
	}
	return ociref.Reference(ref).String()
}

// like [Reference.String], but also stripping a known digest if this object's value matches
func (ref Reference) StringWithKnownDigest(commonDigest ociregistry.Digest) string {
	if ref.Digest == commonDigest {
		ref.Digest = ""
	}
	return ref.String()
}

// implements [encoding.TextMarshaler] (especially for [Reference]-in-JSON)
func (ref Reference) MarshalText() ([]byte, error) {
	return []byte(ref.String()), nil
}

// implements [encoding.TextUnmarshaler] (especially for [Reference]-from-JSON)
func (ref *Reference) UnmarshalText(text []byte) error {
	r, err := ParseRef(string(text))
	if err == nil {
		*ref = r
	}
	return err
}
