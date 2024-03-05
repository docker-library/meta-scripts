package registry

import (
	"context"
	"io"
	"sync"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ocimem"
)

// https://github.com/opencontainers/distribution-spec/pull/293#issuecomment-1452780554
// TODO this should probably be submitted as a "const" in the image-spec ("ocispec.SuggestedManifestSizeLimit" or somesuch)
const manifestSizeLimit = 4 * 1024 * 1024

// this implements a transparent in-memory cache on top of objects less than 4MiB in size from the given registry -- it (currently) assumes a short lifecycle, not a long-running program, so use with care!
//
// TODO options (so we can control *what* gets cached, such as our size limit, whether to cache tag lookups, whether cached data should have a TTL, etc; see manifestSizeLimit and getBlob)
func RegistryCache(r ociregistry.Interface) ociregistry.Interface {
	return &registryCache{
		registry: r, // TODO support "nil" here so this can be a poor-man's ocimem implementation? 👀  see also https://github.com/cue-labs/oci/issues/24
		has:      map[string]bool{},
		tags:     map[string]ociregistry.Digest{},
		data:     map[ociregistry.Digest]ociregistry.Descriptor{},
	}
}

type registryCache struct {
	*ociregistry.Funcs

	registry ociregistry.Interface

	// https://github.com/cue-labs/oci/issues/24
	mu   sync.Mutex                                    // TODO some kind of per-object/name/digest mutex so we don't request the same object from the upstream registry concurrently (on *top* of our maps mutex)?
	has  map[string]bool                               // "repo/name@digest" => true (whether a given repo has the given digest)
	tags map[string]ociregistry.Digest                 // "repo/name:tag" => digest
	data map[ociregistry.Digest]ociregistry.Descriptor // digest => mediaType+size(+data) (most recent *storing* / "cache-miss" lookup wins, in the case of upstream/cross-repo ambiguity)
}

func cacheKeyDigest(repo string, digest ociregistry.Digest) string {
	return repo + "@" + digest.String()
}

func cacheKeyTag(repo, tag string) string {
	return repo + ":" + tag
}

// a helper that implements GetBlob and GetManifest generically (since they're the same function signature and it doesn't really help *us* to treat those object types differently here)
func (rc *registryCache) getBlob(ctx context.Context, repo string, digest ociregistry.Digest, f func(ctx context.Context, repo string, digest ociregistry.Digest) (ociregistry.BlobReader, error)) (ociregistry.BlobReader, error) {
	rc.mu.Lock()
	defer rc.mu.Unlock()

	if desc, ok := rc.data[digest]; ok && desc.Data != nil && rc.has[cacheKeyDigest(repo, digest)] {
		return ocimem.NewBytesReader(desc.Data, desc), nil
	}

	r, err := f(ctx, repo, digest)
	if err != nil {
		return nil, err
	}
	// defer r.Close() happens later when we know we aren't making Close the caller's responsibility

	desc := r.Descriptor()
	digest = desc.Digest // if this isn't a no-op, we've got a naughty registry

	rc.has[cacheKeyDigest(repo, digest)] = true

	if desc.Size > manifestSizeLimit {
		rc.data[digest] = desc
		return r, nil
	}
	defer r.Close()

	desc.Data, err = io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	if err := r.Close(); err != nil {
		return nil, err
	}

	rc.data[digest] = desc

	return ocimem.NewBytesReader(desc.Data, desc), nil
}

func (rc *registryCache) GetBlob(ctx context.Context, repo string, digest ociregistry.Digest) (ociregistry.BlobReader, error) {
	return rc.getBlob(ctx, repo, digest, rc.registry.GetBlob)
}

func (rc *registryCache) GetManifest(ctx context.Context, repo string, digest ociregistry.Digest) (ociregistry.BlobReader, error) {
	return rc.getBlob(ctx, repo, digest, rc.registry.GetManifest)
}

func (rc *registryCache) GetTag(ctx context.Context, repo string, tag string) (ociregistry.BlobReader, error) {
	rc.mu.Lock()
	defer rc.mu.Unlock()

	tagKey := cacheKeyTag(repo, tag)

	if digest, ok := rc.tags[tagKey]; ok {
		if desc, ok := rc.data[digest]; ok && desc.Data != nil {
			return ocimem.NewBytesReader(desc.Data, desc), nil
		}
	}

	r, err := rc.registry.GetTag(ctx, repo, tag)
	if err != nil {
		return nil, err
	}
	// defer r.Close() happens later when we know we aren't making Close the caller's responsibility

	desc := r.Descriptor()

	rc.has[cacheKeyDigest(repo, desc.Digest)] = true
	rc.tags[tagKey] = desc.Digest

	if desc.Size > manifestSizeLimit {
		rc.data[desc.Digest] = desc
		return r, nil
	}
	defer r.Close()

	desc.Data, err = io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	if err := r.Close(); err != nil {
		return nil, err
	}

	rc.data[desc.Digest] = desc

	return ocimem.NewBytesReader(desc.Data, desc), nil
}

func (rc *registryCache) resolveBlob(ctx context.Context, repo string, digest ociregistry.Digest, f func(ctx context.Context, repo string, digest ociregistry.Digest) (ociregistry.Descriptor, error)) (ociregistry.Descriptor, error) {
	rc.mu.Lock()
	defer rc.mu.Unlock()

	if desc, ok := rc.data[digest]; ok && rc.has[cacheKeyDigest(repo, digest)] {
		return desc, nil
	}

	desc, err := f(ctx, repo, digest)
	if err != nil {
		return desc, err
	}

	digest = desc.Digest // if this isn't a no-op, we've got a naughty registry

	rc.has[cacheKeyDigest(repo, digest)] = true

	// carefully copy only valid Resolve* fields such that any other existing fields are kept (this matters more if we ever make our mutexes better/less aggressive 👀)
	if d, ok := rc.data[digest]; ok {
		d.MediaType = desc.MediaType
		d.Digest = desc.Digest
		d.Size = desc.Size
		desc = d
	}
	rc.data[digest] = desc

	return desc, nil
}

func (rc *registryCache) ResolveManifest(ctx context.Context, repo string, digest ociregistry.Digest) (ociregistry.Descriptor, error) {
	return rc.resolveBlob(ctx, repo, digest, rc.registry.ResolveManifest)
}

func (rc *registryCache) ResolveBlob(ctx context.Context, repo string, digest ociregistry.Digest) (ociregistry.Descriptor, error) {
	return rc.resolveBlob(ctx, repo, digest, rc.registry.ResolveBlob)
}

func (rc *registryCache) ResolveTag(ctx context.Context, repo string, tag string) (ociregistry.Descriptor, error) {
	rc.mu.Lock()
	defer rc.mu.Unlock()

	tagKey := cacheKeyTag(repo, tag)

	if digest, ok := rc.tags[tagKey]; ok {
		if desc, ok := rc.data[digest]; ok {
			return desc, nil
		}
	}

	desc, err := rc.registry.ResolveTag(ctx, repo, tag)
	if err != nil {
		return desc, err
	}

	rc.has[cacheKeyDigest(repo, desc.Digest)] = true
	rc.tags[tagKey] = desc.Digest

	// carefully copy only valid Resolve* fields such that any other existing fields are kept (this matters more if we ever make our mutexes better/less aggressive 👀)
	if d, ok := rc.data[desc.Digest]; ok {
		d.MediaType = desc.MediaType
		d.Digest = desc.Digest
		d.Size = desc.Size
		desc = d
	}
	rc.data[desc.Digest] = desc

	return desc, nil
}

func (rc *registryCache) PushManifest(ctx context.Context, repo string, tag string, contents []byte, mediaType string) (ociregistry.Descriptor, error) {
	// TODO this does *not* need to lock the entire cache during the upstream push (but it *would* be good to block pushing to this specific tag)
	rc.mu.Lock()
	defer rc.mu.Unlock()

	desc, err := rc.registry.PushManifest(ctx, repo, tag, contents, mediaType)
	if err != nil {
		return ociregistry.Descriptor{}, err
	}

	rc.has[cacheKeyDigest(repo, desc.Digest)] = true
	if tag != "" {
		rc.tags[cacheKeyTag(repo, tag)] = desc.Digest
	}
	rc.types[desc.Digest] = desc.MediaType
	if len(contents) <= manifestSizeLimit {
		rc.data[desc.Digest] = contents
	} else {
		delete(rc.data, desc.Digest)
	}

	return desc, nil
}

func (rc *registryCache) PushBlob(ctx context.Context, repo string, desc ociregistry.Descriptor, r io.Reader) (ociregistry.Descriptor, error) {
	// TODO this does *not* need to lock the entire cache during the upstream push (but it *would* be good to block pushing to this specific digest)
	rc.mu.Lock()
	defer rc.mu.Unlock()

	// TODO if desc.Size <= manifestSizeLimit, we should technically wrap up the Reader we're given and cache the result so we can shove it directly into the cache, but we currently don't read back blobs we pushed in (and I don't think that's a common use case), so I'm taking the simpler answer of just using this event as a cache bust intead

	desc, err := rc.registry.PushBlob(ctx, repo, desc, r)
	if err != nil {
		return ociregistry.Descriptor{}, err
	}

	rc.has[cacheKeyDigest(repo, desc.Digest)] = true
	rc.types[desc.Digest] = desc.MediaType
	delete(rc.data, desc.Digest) // see TODO above

	return desc, nil
}

func (rc *registryCache) MountBlob(ctx context.Context, fromRepo, toRepo string, digest ociregistry.Digest) (ociregistry.Descriptor, error) {
	// TODO this does *not* need to lock the entire cache during the upstream push (but it *would* be good to block pushing to this specific digest)
	rc.mu.Lock()
	defer rc.mu.Unlock()

	desc, err := rc.registry.MountBlob(ctx, fromRepo, toRepo, digest)
	if err != nil {
		return ociregistry.Descriptor{}, err
	}

	rc.has[cacheKeyDigest(toRepo, desc.Digest)] = true // TODO technically we should also be able to safely imply that "fromRepo" has digest here too, but need to double check whether the contract of the MountBlob API in OCI is such that it's legal for it to return success if "toRepo" already has "digest" (even if "fromRepo" doesn't)
	rc.types[desc.Digest] = desc.MediaType

	return desc, nil
}

// TODO more methods (currently only implements what's actually necessary for SynthesizeIndex and PushIndex)
