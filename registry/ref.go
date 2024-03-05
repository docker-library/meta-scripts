package registry

import (
	"strings"

	// thanks, go-digest...
	_ "crypto/sha256"
	_ "crypto/sha512"

	"cuelabs.dev/go/oci/ociregistry/ociref"
)

// parse a ref like `hello-world:latest` into an [ociref.Reference] object, with Docker Hub canonicalization applied: `docker.io/library/hello-world:latest`
//
// See also [ociref.ParseRelative]
//
// NOTE: this explicitly does *not* normalize Tag to `:latest` because it's useful to be able to parse a reference and know it did not specify either tag or digest (and `if ref.Tag == "" { ref.Tag = "latest" }` is really trivial code outside this for that case)
func ParseRefNormalized(img string) (ociref.Reference, error) {
	ref, err := ociref.ParseRelative(img)
	if err != nil {
		return ociref.Reference{}, err
	}
	if dockerHubHosts[ref.Host] {
		// normalize Docker Hub host value
		ref.Host = dockerHubCanonical
		// normalize Docker Official Images to library/ prefix
		if !strings.Contains(ref.Repository, "/") {
			ref.Repository = "library/" + ref.Repository
		}
	}
	return ref, nil
}
