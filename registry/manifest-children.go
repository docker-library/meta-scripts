package registry

import (
	"encoding/json"

	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

type ManifestChildren struct {
	// *technically* this should be two separate structs chosen based on mediaType (https://github.com/opencontainers/distribution-spec/security/advisories/GHSA-mc8v-mgrf-8f4m), but that makes the code a lot more annoying when we're just collecting a list of potential children we need to copy over for the parent object to push successfully

	// intentional subset of https://github.com/opencontainers/image-spec/blob/v1.1.0/specs-go/v1/index.go#L21 to minimize parsing
	Manifests []ocispec.Descriptor `json:"manifests"`

	// intentional subset of https://github.com/opencontainers/image-spec/blob/v1.1.0/specs-go/v1/manifest.go#L20 to minimize parsing
	Config *ocispec.Descriptor  `json:"config"` // have to turn this into a pointer so we can recognize when it's not set easier / more correctly
	Layers []ocispec.Descriptor `json:"layers"`
}

// opportunistically parse a given manifest for any *potential* child objects; will return JSON parsing errors for non-JSON
func ParseManifestChildren(manifest []byte) (ManifestChildren, error) {
	var manifestChildren ManifestChildren
	err := json.Unmarshal(manifest, &manifestChildren)
	return manifestChildren, err
}
