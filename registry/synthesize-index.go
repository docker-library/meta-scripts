package registry

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/docker-library/bashbrew/architecture"

	"cuelabs.dev/go/oci/ociregistry"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

// returns a synthesized [ocispec.Index] object for the given reference that includes automatically pulling up [ocispec.Platform] objects for entries missing them plus annotations for bashbrew architecture ([AnnotationBashbrewArch]) and where to find the "upstream" object if it needs to be copied/pulled ([ocispec.AnnotationRefName])
func SynthesizeIndex(ctx context.Context, ref Reference) (*ocispec.Index, error) {
	// consider making this a full ociregistry.Interface object? GetManifest(digest) not returning an object with that digest would certainly be Weird though so maybe that's a misguided idea (with very minimal actual benefit, at least right now)

	client, err := Client(ref.Host, nil)
	if err != nil {
		return nil, fmt.Errorf("%s: failed getting client: %w", ref, err)
	}

	var r ociregistry.BlobReader = nil
	if ref.Digest != "" {
		r, err = client.GetManifest(ctx, ref.Repository, ref.Digest)
	} else {
		tag := ref.Tag
		if tag == "" {
			tag = "latest"
		}
		r, err = client.GetTag(ctx, ref.Repository, tag)
	}
	if err != nil {
		// https://github.com/cue-labs/oci/issues/26
		if errors.Is(err, ociregistry.ErrBlobUnknown) ||
			errors.Is(err, ociregistry.ErrManifestUnknown) ||
			errors.Is(err, ociregistry.ErrNameUnknown) ||
			strings.HasPrefix(err.Error(), "404 ") {
			return nil, nil
		}
		return nil, fmt.Errorf("%s: failed GET: %w", ref, err)
	}
	defer r.Close()

	desc := r.Descriptor()

	var index ocispec.Index

	switch desc.MediaType {
	case ocispec.MediaTypeImageManifest, mediaTypeDockerImageManifest:
		if err := normalizeManifestPlatform(ctx, &desc, r, client, ref); err != nil {
			return nil, fmt.Errorf("%s: failed normalizing manifest platform: %w", ref, err)
		}

		index.Manifests = append(index.Manifests, desc)

	case ocispec.MediaTypeImageIndex, mediaTypeDockerManifestList:
		if err := readJSONHelper(r, &index); err != nil {
			return nil, fmt.Errorf("%s: failed reading index: %w", ref, err)
		}

	default:
		return nil, fmt.Errorf("unsupported mediaType: %q", desc.MediaType)
	}

	switch index.SchemaVersion {
	case 0:
		index.SchemaVersion = 2
	case 2:
		// all good, do nothing!
	default:
		return nil, fmt.Errorf("unsupported index schemaVersion: %q", index.SchemaVersion)
	}

	switch index.MediaType {
	case "":
		index.MediaType = ocispec.MediaTypeImageIndex
		if len(index.Manifests) >= 1 {
			// if the first item in our list is a Docker media type, our list should probably be too
			if index.Manifests[0].MediaType == mediaTypeDockerImageManifest {
				index.MediaType = mediaTypeDockerManifestList
			}
		}
	case ocispec.MediaTypeImageIndex, mediaTypeDockerManifestList:
		// all good, do nothing!
	default:
		return nil, fmt.Errorf("unsupported index mediaType: %q", index.MediaType)
	}

	setRefAnnotation(&index.Annotations, ref, desc.Digest)

	seen := map[string]*ociregistry.Descriptor{}
	i := 0 // https://go.dev/wiki/SliceTricks#filter-in-place (used to delete references we don't have the subject of)
	for _, m := range index.Manifests {
		if seen[string(m.Digest)] != nil {
			// skip digests we've already seen (de-dupe), since we have a map already for dropping dangling attestations
			continue
			// if there was unique data on this lower entry (different annotations, etc), perhaps we should merge/overwrite?  OCI spec technically says "first match SHOULD win", so this is probably fine/sane
			// https://github.com/opencontainers/image-spec/blob/v1.1.0/image-index.md#:~:text=If%20multiple%20manifests%20match%20a%20client%20or%20runtime%27s%20requirements%2C%20the%20first%20matching%20entry%20SHOULD%20be%20used.
		}

		setRefAnnotation(&m.Annotations, ref, m.Digest)

		if err := normalizeManifestPlatform(ctx, &m, nil, client, ref); err != nil {
			return nil, fmt.Errorf("%s: failed normalizing manifest platform: %w", m.Annotations[ocispec.AnnotationRefName], err)
		}

		delete(m.Annotations, AnnotationBashbrewArch) // don't trust any remote-provided value for bashbrew arch (since it's really inexpensive for us to calculate fresh and it's only a hint anyhow)
		if m.Annotations[annotationBuildkitReferenceType] == annotationBuildkitReferenceTypeAttestation {
			if subject := seen[m.Annotations[annotationBuildkitReferenceDigest]]; subject != nil && subject.Annotations[AnnotationBashbrewArch] != "" {
				m.Annotations[AnnotationBashbrewArch] = subject.Annotations[AnnotationBashbrewArch]
			} else {
				// if our subject is missing, delete this entry from the index (see "i")
				continue
			}
		} else if m.Platform != nil {
			imagePlatform := architecture.OCIPlatform(*m.Platform)
			// match "platform" to bashbrew arch and set an appropriate annotation
			for bashbrewArch, supportedPlatform := range architecture.SupportedArches {
				if imagePlatform.Is(supportedPlatform) {
					m.Annotations[AnnotationBashbrewArch] = bashbrewArch
					break
				}
			}
		}

		index.Manifests[i] = m
		seen[string(m.Digest)] = &index.Manifests[i]
		i++
	}
	index.Manifests = index.Manifests[:i] // https://go.dev/wiki/SliceTricks#filter-in-place

	// TODO set an annotation on the index to specify whether or not we actually filtered anything (or whether it's safe to copy the original index as-is during arch-specific deploy instead of reconstructing it from all the parts); maybe a list of digests that were skipped/excluded?

	return &index, nil
}

// given a (potentially `nil`) map of annotations, add [ocispec.AnnotationRefName] including the supplied [Reference] (but with [Reference.Digest] set to a new value)
func setRefAnnotation(annotations *map[string]string, ref Reference, digest ociregistry.Digest) {
	if *annotations == nil {
		// "assignment to nil map" 🙃
		*annotations = map[string]string{}
	}
	ref.Digest = digest // since ref is already copied by value, we're safe to modify it to inject the new digest
	(*annotations)[ocispec.AnnotationRefName] = ref.String()
}

// given a manifest descriptor (and optionally an existing [ociregistry.BlobReader] on the manifest object itself), make sure it has a valid [ocispec.Platform] object if possible, querying down into the [ocispec.Image] ("config" blob) if necessary
func normalizeManifestPlatform(ctx context.Context, m *ocispec.Descriptor, r ociregistry.BlobReader, client ociregistry.Interface, ref Reference) error {
	if m.Platform == nil || m.Platform.OS == "" || m.Platform.Architecture == "" {
		// if missing (or obviously invalid) "platform", we need to (maybe) reach downwards and synthesize
		m.Platform = nil

		switch m.MediaType {
		case ocispec.MediaTypeImageManifest, mediaTypeDockerImageManifest:
			var err error
			if r == nil {
				r, err = client.GetManifest(ctx, ref.Repository, m.Digest)
				if err != nil {
					return err
				}
				defer r.Close()
			}

			var manifest ocispec.Manifest
			if err := readJSONHelper(r, &manifest); err != nil {
				return err
			}

			switch manifest.Config.MediaType {
			case ocispec.MediaTypeImageConfig, mediaTypeDockerImageConfig:
				r, err := client.GetBlob(ctx, ref.Repository, manifest.Config.Digest)
				if err != nil {
					return err
				}
				defer r.Close()

				var config ocispec.Image
				if err := readJSONHelper(r, &config); err != nil {
					return err
				}

				if config.Platform.OS != "" && config.Platform.Architecture != "" {
					m.Platform = &config.Platform
				}
			}
		}
	}

	if m.Platform != nil {
		// if we have a platform object now, let's normalize it
		normal := architecture.Normalize(*m.Platform)
		m.Platform = &normal
	}

	return nil
}
