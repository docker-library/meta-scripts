package registry

const (
	AnnotationBashbrewArch = "com.docker.official-images.bashbrew.arch"

	// https://docs.docker.com/build/attestations/attestation-storage/
	annotationBuildkitReferenceType            = "vnd.docker.reference.type"
	annotationBuildkitReferenceTypeAttestation = "attestation-manifest"
	annotationBuildkitReferenceDigest          = "vnd.docker.reference.digest"

	// https://github.com/distribution/distribution/blob/v3.0.0-alpha.1/docs/content/spec/manifest-v2-2.md
	mediaTypeDockerManifestList  = "application/vnd.docker.distribution.manifest.list.v2+json"
	mediaTypeDockerImageManifest = "application/vnd.docker.distribution.manifest.v2+json"
	mediaTypeDockerImageConfig   = "application/vnd.docker.container.image.v1+json"
)
