package registry

const (
	AnnotationBashbrewArch = "com.docker.official-images.bashbrew.arch"

	// https://github.com/moby/buildkit/blob/c6145c2423de48f891862ac02f9b2653864d3c9e/docs/attestations/attestation-storage.md
	annotationBuildkitReferenceType            = "vnd.docker.reference.type"
	annotationBuildkitReferenceTypeAttestation = "attestation-manifest"
	annotationBuildkitReferenceDigest          = "vnd.docker.reference.digest"

	// https://github.com/distribution/distribution/blob/v3.0.0/docs/content/spec/manifest-v2-2.md
	mediaTypeDockerManifestList  = "application/vnd.docker.distribution.manifest.list.v2+json"
	mediaTypeDockerImageManifest = "application/vnd.docker.distribution.manifest.v2+json"
	mediaTypeDockerImageConfig   = "application/vnd.docker.container.image.v1+json"
)
