package registry_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/docker-library/meta-scripts/registry"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ociauth"
	"cuelabs.dev/go/oci/ociregistry/ocimem"
	"cuelabs.dev/go/oci/ociregistry/ociserver"
	godigest "github.com/opencontainers/go-digest"
	specs "github.com/opencontainers/image-spec/specs-go"
	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
)

// a fake registry that is an in-memory OCI registry plus an emulation of Docker Hub's "POST /v2/<dst>/_docker/copy/image" endpoint (and all the interesting ways it can fail)

type fakeHubMode int

const (
	// Docker Hub with the feature enabled for the namespaces involved
	hubWorks fakeHubMode = iota
	// Docker Hub with the feature *not* enabled for the namespaces involved (nothing is mounted, so the manifest is rejected for missing blobs)
	hubFlagOff
	// any other registry (plain text 404)
	hubNoRoute
	// the endpoint exists, but is having a bad day
	hubBroken
	// the endpoint claims success, but did not copy what we asked for
	hubWrongDigest
	// any other registry (plain text 404) which also reports a manifest push with missing children as a 500 instead of a 4xx (which is what "ocimem" does, and the spec does not forbid)
	hubMissingChildren500
)

type fakeHub struct {
	t        *testing.T
	Host     string
	Registry *ocimem.Registry

	mode        fakeHubMode
	requireAuth bool

	mu          sync.Mutex
	requests    []string // "METHOD /request/uri" (only requests that made it past authentication)
	tokenScopes []string // the "scope" values of every token request (one entry per request, space separated)
}

func newFakeHub(t *testing.T, mode fakeHubMode, requireAuth bool) *fakeHub {
	t.Helper()

	h := &fakeHub{
		t:           t,
		Registry:    ocimem.New(),
		mode:        mode,
		requireAuth: requireAuth,
	}
	backend := ociserver.New(h.Registry, nil)

	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			h.mu.Lock()
			h.tokenScopes = append(h.tokenScopes, strings.Join(r.URL.Query()["scope"], " "))
			h.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"token":"fake"}`)
			return
		}
		if h.requireAuth && r.Header.Get("Authorization") != "Bearer fake" {
			w.Header().Set("Www-Authenticate", fmt.Sprintf(`Bearer realm="http://%s/token",service="fake"`, h.Host))
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		h.mu.Lock()
		h.requests = append(h.requests, r.Method+" "+r.URL.RequestURI())
		h.mu.Unlock()

		if repo, ok := strings.CutSuffix(strings.TrimPrefix(r.URL.Path, "/v2/"), "/_docker/copy/image"); ok && strings.HasPrefix(r.URL.Path, "/v2/") {
			h.copyImage(w, r, repo)
			return
		}
		if r.Method == http.MethodPut && strings.Contains(r.URL.Path, "/manifests/") && !h.manifestChildrenExist(w, r) {
			return
		}
		backend.ServeHTTP(w, r)
	}))
	// registry.Client assumes "localhost" means plain HTTP, so we need to be listening on "localhost" (and every hub has a unique port, so a unique "host" for all the process-wide caches)
	l, err := net.Listen("tcp", "localhost:0")
	if err != nil {
		t.Fatal(err)
	}
	srv.Listener.Close()
	srv.Listener = l
	srv.Start()
	t.Cleanup(srv.Close)

	_, port, err := net.SplitHostPort(l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	h.Host = "localhost:" + port
	return h
}

// like Docker Hub (and unlike "ocimem", which gives a 500, see [hubMissingChildren500]), reject a manifest push with 400 MANIFEST_BLOB_UNKNOWN if any of its children do not exist in the repository (this is what tells clients they need to copy children and try again)
func (h *fakeHub) manifestChildrenExist(w http.ResponseWriter, r *http.Request) bool {
	status, code := http.StatusBadRequest, "MANIFEST_BLOB_UNKNOWN"
	if h.mode == hubMissingChildren500 {
		status, code = http.StatusInternalServerError, "UNKNOWN"
	}

	repo, _, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/v2/"), "/manifests/")
	body, err := io.ReadAll(r.Body)
	r.Body.Close()
	if err != nil {
		h.t.Error(err)
	}
	r.Body = io.NopCloser(bytes.NewReader(body))

	children, _ := registry.ParseManifestChildren(body) // (not JSON, not our problem)
	ctx := r.Context()
	for _, child := range children.Manifests {
		if _, err := h.Registry.ResolveManifest(ctx, repo, child.Digest); err != nil {
			writeErrors(w, status, code)
			return false
		}
	}
	blobs := children.Layers
	if children.Config != nil {
		blobs = append(blobs, *children.Config)
	}
	for _, blob := range blobs {
		if _, err := h.Registry.ResolveBlob(ctx, repo, blob.Digest); err != nil {
			writeErrors(w, status, code)
			return false
		}
	}
	return true
}

func (h *fakeHub) ref(repo, tag string, digest ociregistry.Digest) registry.Reference {
	return registry.Reference{Host: h.Host, Repository: repo, Tag: tag, Digest: digest}
}

func writeErrors(w http.ResponseWriter, status int, codes ...string) {
	type e struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	var errs struct {
		Errors []e `json:"errors"`
	}
	for _, code := range codes {
		errs.Errors = append(errs.Errors, e{Code: code, Message: strings.ToLower(code)})
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(errs)
}

func (h *fakeHub) copyImage(w http.ResponseWriter, r *http.Request, dstRepo string) {
	switch h.mode {
	case hubNoRoute, hubMissingChildren500:
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprintln(w, "404 page not found")
		return
	case hubFlagOff:
		writeErrors(w, http.StatusBadRequest, "MANIFEST_BLOB_UNKNOWN", "MANIFEST_BLOB_UNKNOWN")
		return
	case hubBroken:
		writeErrors(w, http.StatusInternalServerError, "UNKNOWN")
		return
	case hubWrongDigest:
		w.Header().Set("Docker-Content-Digest", "sha256:"+strings.Repeat("0", 64))
		w.WriteHeader(http.StatusCreated)
		return
	}

	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	query := r.URL.Query()
	desc, err := h.CopyTree(r.Context(), query.Get("from"), dstRepo, ociregistry.Digest(query.Get("reference")), query.Get("tag"))
	if err != nil {
		writeErrors(w, http.StatusNotFound, "MANIFEST_UNKNOWN")
		return
	}
	w.Header().Set("Docker-Content-Digest", string(desc.Digest))
	w.WriteHeader(http.StatusCreated)
}

// copies a manifest, every child manifest, and every blob between repositories (what the real endpoint does for us)
func (h *fakeHub) CopyTree(ctx context.Context, from, to string, digest ociregistry.Digest, tag string) (ociregistry.Descriptor, error) {
	r, err := h.Registry.GetManifest(ctx, from, digest)
	if err != nil {
		return ociregistry.Descriptor{}, err
	}
	desc := r.Descriptor()
	data, err := io.ReadAll(r)
	r.Close()
	if err != nil {
		return desc, err
	}

	children, err := registry.ParseManifestChildren(data)
	if err != nil {
		return desc, err
	}
	for _, child := range children.Manifests {
		if _, err := h.CopyTree(ctx, from, to, child.Digest, ""); err != nil {
			return desc, err
		}
	}
	blobs := children.Layers
	if children.Config != nil {
		blobs = append(blobs, *children.Config)
	}
	for _, blob := range blobs {
		if _, err := h.Registry.MountBlob(ctx, from, to, blob.Digest); err != nil {
			return desc, err
		}
	}
	return h.Registry.PushManifest(ctx, to, tag, data, desc.MediaType)
}

func (h *fakeHub) matching(match func(request string) bool) []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var matched []string
	for _, request := range h.requests {
		if match(request) {
			matched = append(matched, request)
		}
	}
	return matched
}

// requests to the (Hub-specific) copy endpoint
func (h *fakeHub) copyRequests() []string {
	return h.matching(func(request string) bool {
		return strings.HasPrefix(request, "POST ") && strings.Contains(request, "/_docker/copy/image")
	})
}

// blob mount requests (the standard way of copying a blob between repositories)
func (h *fakeHub) mountRequests() []string {
	return h.matching(func(request string) bool {
		return strings.HasPrefix(request, "POST ") && strings.Contains(request, "/blobs/uploads/") && strings.Contains(request, "mount=")
	})
}

func (h *fakeHub) resetRequests() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.requests = nil
}

type testImage struct {
	manifest ocispec.Descriptor
	blobs    []ocispec.Descriptor // config, then layers
}

type testIndex struct {
	desc   ocispec.Descriptor
	data   []byte
	images []testImage
}

func pushTestBlob(t *testing.T, reg ociregistry.Interface, repo, mediaType string, content []byte) ocispec.Descriptor {
	t.Helper()
	desc := ocispec.Descriptor{
		MediaType: mediaType,
		Digest:    godigest.FromBytes(content),
		Size:      int64(len(content)),
	}
	if _, err := reg.PushBlob(context.Background(), repo, desc, bytes.NewReader(content)); err != nil {
		t.Fatalf("pushing blob to %s: %v", repo, err)
	}
	return desc
}

func pushTestManifest(t *testing.T, reg ociregistry.Interface, repo, tag, mediaType string, v any) (ocispec.Descriptor, []byte) {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reg.PushManifest(context.Background(), repo, tag, data, mediaType); err != nil {
		t.Fatalf("pushing manifest to %s: %v", repo, err)
	}
	return ocispec.Descriptor{MediaType: mediaType, Digest: godigest.FromBytes(data), Size: int64(len(data))}, data
}

// pushes an image index of "n" distinct single-platform images (each with a config and two layers) to the given repository
func pushTestIndex(t *testing.T, reg ociregistry.Interface, repo, tag, seed string, n int) testIndex {
	t.Helper()

	var index testIndex
	manifest := ocispec.Index{
		Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: ocispec.MediaTypeImageIndex,
	}
	for i := 0; i < n; i++ {
		config := pushTestBlob(t, reg, repo, ocispec.MediaTypeImageConfig, []byte(fmt.Sprintf(`{"seed":%q,"image":%d}`, seed, i)))
		layers := []ocispec.Descriptor{
			pushTestBlob(t, reg, repo, ocispec.MediaTypeImageLayer, []byte(fmt.Sprintf("%s image %d layer 1", seed, i))),
			pushTestBlob(t, reg, repo, ocispec.MediaTypeImageLayer, []byte(fmt.Sprintf("%s image %d layer 2", seed, i))),
		}
		desc, _ := pushTestManifest(t, reg, repo, "", ocispec.MediaTypeImageManifest, ocispec.Manifest{
			Versioned: specs.Versioned{SchemaVersion: 2},
			MediaType: ocispec.MediaTypeImageManifest,
			Config:    config,
			Layers:    layers,
		})
		index.images = append(index.images, testImage{
			manifest: desc,
			blobs:    append([]ocispec.Descriptor{config}, layers...),
		})

		desc.Platform = &ocispec.Platform{OS: "linux", Architecture: fmt.Sprintf("arch%d", i)}
		manifest.Manifests = append(manifest.Manifests, desc)
	}
	index.desc, index.data = pushTestManifest(t, reg, repo, tag, ocispec.MediaTypeImageIndex, manifest)
	return index
}

// verifies that everything about the given index (including every child and every blob) exists in the given repository (and the given tag, if any, points to it)
func assertCopied(t *testing.T, hub *fakeHub, repo, tag string, index testIndex) {
	t.Helper()
	ctx := context.Background()

	if desc, err := hub.Registry.ResolveManifest(ctx, repo, index.desc.Digest); err != nil {
		t.Errorf("%s: missing index %s: %v", repo, index.desc.Digest, err)
	} else if desc.Digest != index.desc.Digest {
		t.Errorf("%s: index digest mismatch: %s vs %s", repo, desc.Digest, index.desc.Digest)
	}
	if tag != "" {
		if desc, err := hub.Registry.ResolveTag(ctx, repo, tag); err != nil {
			t.Errorf("%s:%s: missing tag: %v", repo, tag, err)
		} else if desc.Digest != index.desc.Digest {
			t.Errorf("%s:%s: tag points to %s, not %s", repo, tag, desc.Digest, index.desc.Digest)
		}
	}
	for _, image := range index.images {
		if _, err := hub.Registry.ResolveManifest(ctx, repo, image.manifest.Digest); err != nil {
			t.Errorf("%s: missing child manifest %s: %v", repo, image.manifest.Digest, err)
		}
		for _, blob := range image.blobs {
			if _, err := hub.Registry.ResolveBlob(ctx, repo, blob.Digest); err != nil {
				t.Errorf("%s: missing blob %s: %v", repo, blob.Digest, err)
			}
		}
	}
}

func assertRequestCount(t *testing.T, what string, requests []string, expected int) {
	t.Helper()
	if len(requests) != expected {
		t.Errorf("expected %d %s request(s), got %d: %q", expected, what, len(requests), requests)
	}
}

// the "lookup" a real deploy would have for an index: every child comes from the same source repository
func lookupFor(hub *fakeHub, repo string) map[ociregistry.Digest]registry.Reference {
	return map[ociregistry.Digest]registry.Reference{"": hub.ref(repo, "", "")}
}

func TestServerSideCopyCopyManifest(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	hub := newFakeHub(t, hubWorks, false)
	index := pushTestIndex(t, hub.Registry, "ns/src", "latest", "copy", 3)

	desc, err := registry.CopyManifest(ctx, hub.ref("ns/src", "latest", ""), hub.ref("ns/dst", "copied", ""), map[ociregistry.Digest]registry.Reference{})
	if err != nil {
		t.Fatal(err)
	}
	if desc.Digest != index.desc.Digest || desc.MediaType != index.desc.MediaType || desc.Size != index.desc.Size {
		t.Errorf("unexpected descriptor: %+v (vs %+v)", desc, index.desc)
	}
	assertCopied(t, hub, "ns/dst", "copied", index)

	// one request for the whole tree, and no client side blob mounting at all
	copyRequests := hub.copyRequests()
	assertRequestCount(t, "copy", copyRequests, 1)
	assertRequestCount(t, "blob mount", hub.mountRequests(), 0)
	if len(copyRequests) == 1 {
		u, err := url.Parse(strings.TrimPrefix(copyRequests[0], "POST "))
		if err != nil {
			t.Fatal(err)
		}
		if u.Path != "/v2/ns/dst/_docker/copy/image" {
			t.Errorf("unexpected path: %s", u.Path)
		}
		expected := url.Values{"from": {"ns/src"}, "reference": {string(index.desc.Digest)}, "tag": {"copied"}}
		if u.Query().Encode() != expected.Encode() {
			t.Errorf("unexpected query: %s (expected %s)", u.Query().Encode(), expected.Encode())
		}
	}
}

func TestServerSideCopyCopyManifestByDigest(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	hub := newFakeHub(t, hubWorks, false)
	index := pushTestIndex(t, hub.Registry, "ns/src", "latest", "bydigest", 2)

	// pushing by digest only means no tag should be created at all (even though the source was a tag)
	if _, err := registry.CopyManifest(ctx, hub.ref("ns/src", "latest", ""), hub.ref("ns/dst", "", index.desc.Digest), map[ociregistry.Digest]registry.Reference{}); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "ns/dst", "", index)

	copyRequests := hub.copyRequests()
	assertRequestCount(t, "copy", copyRequests, 1)
	if len(copyRequests) == 1 && strings.Contains(copyRequests[0], "tag=") {
		t.Errorf("unexpected tag in copy request: %s", copyRequests[0])
	}
	if _, err := hub.Registry.ResolveTag(ctx, "ns/dst", "latest"); err == nil {
		t.Error("unexpected tag \"latest\" in destination")
	}
}

func TestServerSideCopyEnsureManifestChildren(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// this is the "real world" shape for deploy: the index is pushed from raw data, and its children have to come from somewhere else
	hub := newFakeHub(t, hubWorks, false)
	index := pushTestIndex(t, hub.Registry, "ns/src", "", "children", 4)

	desc, err := registry.EnsureManifest(ctx, hub.ref("ns/dst", "latest", ""), index.data, index.desc.MediaType, lookupFor(hub, "ns/src"))
	if err != nil {
		t.Fatal(err)
	}
	if desc.Digest != index.desc.Digest {
		t.Errorf("unexpected digest: %s", desc.Digest)
	}
	assertCopied(t, hub, "ns/dst", "latest", index)

	// one copy per child (the index itself is a normal push), and no client side blob mounting at all
	assertRequestCount(t, "copy", hub.copyRequests(), 4)
	assertRequestCount(t, "blob mount", hub.mountRequests(), 0)
}

func TestServerSideCopyEnsureManifestExistingChildren(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	hub := newFakeHub(t, hubWorks, false)
	index := pushTestIndex(t, hub.Registry, "ns/src", "", "existing", 3)

	// one child is already (completely) there, so we should not ask for it again
	if _, err := hub.CopyTree(ctx, "ns/src", "ns/dst", index.images[0].manifest.Digest, ""); err != nil {
		t.Fatal(err)
	}

	if _, err := registry.EnsureManifest(ctx, hub.ref("ns/dst", "latest", ""), index.data, index.desc.MediaType, lookupFor(hub, "ns/src")); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "ns/dst", "latest", index)
	assertRequestCount(t, "copy", hub.copyRequests(), 2)
	assertRequestCount(t, "blob mount", hub.mountRequests(), 0)
}

func TestServerSideCopyIdempotent(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	hub := newFakeHub(t, hubWorks, false)
	index := pushTestIndex(t, hub.Registry, "ns/src", "latest", "idempotent", 3)

	for _, dst := range []registry.Reference{hub.ref("ns/dst", "latest", ""), hub.ref("ns/dst", "latest", "")} {
		hub.resetRequests()
		if _, err := registry.CopyManifest(ctx, hub.ref("ns/src", "latest", ""), dst, map[ociregistry.Digest]registry.Reference{}); err != nil {
			t.Fatal(err)
		}
		assertCopied(t, hub, "ns/dst", "latest", index)
	}
	// the second time around, everything is already there, so we should not even be asking
	assertRequestCount(t, "copy", hub.copyRequests(), 0)
	assertRequestCount(t, "blob mount", hub.mountRequests(), 0)
}

func TestServerSideCopyRouteMissing(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// any registry that is not Docker Hub (or is, but without this feature)
	hub := newFakeHub(t, hubNoRoute, false)
	index := pushTestIndex(t, hub.Registry, "ns/src", "", "noroute", 3)

	if _, err := registry.EnsureManifest(ctx, hub.ref("ns/dst", "latest", ""), index.data, index.desc.MediaType, lookupFor(hub, "ns/src")); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "ns/dst", "latest", index)
	assertRequestCount(t, "copy", hub.copyRequests(), 1) // we only asked the first time
	assertRequestCount(t, "blob mount", hub.mountRequests(), 3*3)

	// and we should have remembered that for the whole host (regardless of repository)
	index2 := pushTestIndex(t, hub.Registry, "other/src", "latest", "noroute2", 2)
	if _, err := registry.CopyManifest(ctx, hub.ref("other/src", "latest", ""), hub.ref("other/dst", "latest", ""), map[ociregistry.Digest]registry.Reference{}); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "other/dst", "latest", index2)
	assertRequestCount(t, "copy", hub.copyRequests(), 1)

	// a registry we know does not work should not cost us anything extra either (the source is only fetched, never resolved separately first)
	assertRequestCount(t, "source HEAD", hub.matching(func(request string) bool {
		return strings.HasPrefix(request, "HEAD /v2/other/src/")
	}), 0)
}

func TestServerSideCopyMissingChildrenReportedAs500(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// "EnsureManifest" only recognizes a 4xx as "some children are missing" (and so does not recognize this registry's 500), which is existing behavior that having a server side copy to try does not change: the error is the same, and we only ask once
	hub := newFakeHub(t, hubMissingChildren500, false)
	index := pushTestIndex(t, hub.Registry, "ns/src", "latest", "500", 2)

	if _, err := registry.EnsureManifest(ctx, hub.ref("ns/dst", "latest", ""), index.data, index.desc.MediaType, lookupFor(hub, "ns/src")); err == nil {
		t.Error("expected an error pushing an index with missing children to a registry that reports a 500 for it")
	}
	assertRequestCount(t, "copy", hub.copyRequests(), 0) // never gets as far as looking for children

	for i := 0; i < 2; i++ {
		if _, err := registry.CopyManifest(ctx, hub.ref("ns/src", "latest", ""), hub.ref("ns/dst", "latest", ""), map[ociregistry.Digest]registry.Reference{}); err == nil {
			t.Error("expected an error copying an index to a registry that reports a 500 for missing children")
		}
	}
	assertRequestCount(t, "copy", hub.copyRequests(), 1) // and we remembered after the first one
	if _, err := hub.Registry.ResolveManifest(ctx, "ns/dst", index.desc.Digest); err == nil {
		t.Error("unexpected index in destination")
	}
}

func TestServerSideCopyFeatureDisabled(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// the endpoint exists, but the feature flag is not on for these namespaces
	hub := newFakeHub(t, hubFlagOff, false)
	index := pushTestIndex(t, hub.Registry, "ns1/src", "", "flagoff", 3)

	if _, err := registry.EnsureManifest(ctx, hub.ref("ns1/dst", "latest", ""), index.data, index.desc.MediaType, lookupFor(hub, "ns1/src")); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "ns1/dst", "latest", index)
	assertRequestCount(t, "copy", hub.copyRequests(), 1)
	assertRequestCount(t, "blob mount", hub.mountRequests(), 3*3)

	// the same pair of namespaces should not be tried again
	if _, err := registry.EnsureManifest(ctx, hub.ref("ns1/dst2", "latest", ""), index.data, index.desc.MediaType, lookupFor(hub, "ns1/src")); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "ns1/dst2", "latest", index)
	assertRequestCount(t, "copy", hub.copyRequests(), 1)

	// but a different pair of namespaces might have the feature enabled, so we have to ask again
	index2 := pushTestIndex(t, hub.Registry, "ns2/src", "", "flagoff2", 2)
	if _, err := registry.EnsureManifest(ctx, hub.ref("ns1/dst3", "latest", ""), index2.data, index2.desc.MediaType, lookupFor(hub, "ns2/src")); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "ns1/dst3", "latest", index2)
	assertRequestCount(t, "copy", hub.copyRequests(), 2)
}

func TestServerSideCopyUntrustworthy(t *testing.T) {
	t.Parallel()

	for name, mode := range map[string]fakeHubMode{
		"server error": hubBroken,
		"wrong digest": hubWrongDigest,
	} {
		name, mode := name, mode
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			ctx := context.Background()

			hub := newFakeHub(t, mode, false)
			index := pushTestIndex(t, hub.Registry, "ns/src", "", "untrustworthy", 3)

			// these are not something we can safely draw a conclusion from, so every child gets its own attempt (and its own fallback, which has to be sufficient to get the right result)
			if _, err := registry.EnsureManifest(ctx, hub.ref("ns/dst", "latest", ""), index.data, index.desc.MediaType, lookupFor(hub, "ns/src")); err != nil {
				t.Fatal(err)
			}
			assertCopied(t, hub, "ns/dst", "latest", index)
			assertRequestCount(t, "copy", hub.copyRequests(), 3)
			assertRequestCount(t, "blob mount", hub.mountRequests(), 3*3)
		})
	}
}

func TestServerSideCopyUnknownSource(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// a source that does not exist is still an error (and a good one, from the client side code)
	hub := newFakeHub(t, hubWorks, false)
	if _, err := registry.CopyManifest(ctx, hub.ref("ns/nope", "latest", ""), hub.ref("ns/dst", "latest", ""), map[ociregistry.Digest]registry.Reference{}); err == nil {
		t.Error("expected an error copying a manifest that does not exist")
	}
	assertRequestCount(t, "copy", hub.copyRequests(), 0)
}

func TestServerSideCopyDigestMismatch(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// explicitly asking for a destination digest that is not the source digest is an error, and not something we should hand to the server
	hub := newFakeHub(t, hubWorks, false)
	pushTestIndex(t, hub.Registry, "ns/src", "latest", "mismatch", 2)

	wrong := godigest.FromString("wrong")
	if _, err := registry.CopyManifest(ctx, hub.ref("ns/src", "latest", ""), hub.ref("ns/dst", "latest", wrong), map[ociregistry.Digest]registry.Reference{}); err == nil {
		t.Error("expected an error for a mismatched destination digest")
	}
	assertRequestCount(t, "copy", hub.copyRequests(), 0)
}

func TestServerSideCopyDifferentHosts(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	// the endpoint can only copy within one registry, so copying between two registries has to stay client side
	src := newFakeHub(t, hubWorks, false)
	dst := newFakeHub(t, hubWorks, false)
	index := pushTestIndex(t, src.Registry, "ns/src", "latest", "hosts", 2)

	if _, err := registry.CopyManifest(ctx, src.ref("ns/src", "latest", ""), dst.ref("ns/dst", "latest", ""), map[ociregistry.Digest]registry.Reference{}); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, dst, "ns/dst", "latest", index)
	assertRequestCount(t, "source copy", src.copyRequests(), 0)
	assertRequestCount(t, "destination copy", dst.copyRequests(), 0)
}

func TestServerSideCopyAuthScopes(t *testing.T) {
	t.Parallel()
	ctx := context.Background()

	hub := newFakeHub(t, hubWorks, true)
	index := pushTestIndex(t, hub.Registry, "ns/src", "latest", "scopes", 2)

	if _, err := registry.CopyManifest(ctx, hub.ref("ns/src", "latest", ""), hub.ref("ns/dst", "latest", ""), map[ociregistry.Digest]registry.Reference{}); err != nil {
		t.Fatal(err)
	}
	assertCopied(t, hub, "ns/dst", "latest", index)
	assertRequestCount(t, "copy", hub.copyRequests(), 1)

	// the copy needs to push (and pull) the destination and pull the source, and (to not need a second token) all in one token
	needed := []ociauth.ResourceScope{
		{ResourceType: "repository", Resource: "ns/dst", Action: "push"},
		{ResourceType: "repository", Resource: "ns/dst", Action: "pull"},
		{ResourceType: "repository", Resource: "ns/src", Action: "pull"},
	}
	hub.mu.Lock()
	defer hub.mu.Unlock()
	for _, scopes := range hub.tokenScopes {
		scope := ociauth.ParseScope(scopes)
		holdsAll := true
		for _, rs := range needed {
			holdsAll = holdsAll && scope.Holds(rs)
		}
		if holdsAll {
			return
		}
	}
	t.Errorf("no token request included %v: %q", needed, hub.tokenScopes)
}
