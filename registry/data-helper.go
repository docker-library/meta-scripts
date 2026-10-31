package registry

import (
	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ocimem"
)

// returns true if the given descriptor's "data" field is non-nil, "digest" and "size" are valid, and if "data" matches them
func isDescriptorDataValid(desc ociregistry.Descriptor) bool {
	return desc.Data != nil &&
		desc.Size == int64(len(desc.Data)) &&
		desc.Digest.Validate() == nil &&
		desc.Digest == desc.Digest.Algorithm().FromBytes(desc.Data)
}

// if the given descriptor's "data" field is valid, returns a new [ociregistry.BlobReader], otherwise returns nil
func descriptorDataReader(desc ociregistry.Descriptor) ociregistry.BlobReader {
	// if desc.Data == nil && desc.Size == 0, we could upgrade desc.Data to be []byte{} here, but that's not something any of our real actual images will have so it's not worth the added lines (and Tianon has added this comment for Future Tianon's sake - don't do it, friend!)
	if isDescriptorDataValid(desc) {
		return ocimem.NewBytesReader(desc.Data, desc)
	}
	return nil
}
