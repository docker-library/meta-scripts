package registry

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ociauth"
)

var (
	// "host" or "host|srcNamespace|dstNamespace" => true once we have good reason to believe a server-side manifest copy cannot work there (so we stop wasting a request on every manifest)
	serverSideCopyDisabled = sync.Map{}
)

func repoNamespace(repo string) string {
	ns, _, _ := strings.Cut(repo, "/")
	return ns
}

// asks the registry to copy the manifest srcRef (by tag or by digest) into dstRef's repository *server side*, including every child manifest, config, and layer (so we don't have to do any per-blob or per-child requests ourselves)
//
// this is Docker Hub's "POST /v2/<dst>/_docker/copy/image?from=<src>&reference=<digest>[&tag=<tag>]" endpoint (basically a blob mount, but for a manifest), which Hub only enables for specific namespaces, so this is explicitly *best effort*: it returns true only if the registry confirmed it copied the right digest (and every child), and false for every other outcome (including "this registry has never heard of that endpoint") -- callers are expected to fall back to copying client side, which will also produce the authoritative error if something is genuinely wrong
//
// a failed attempt has no side effects (the registry stores nothing unless it was able to mount every child)
//
// the returned descriptor always has the right Digest on success, but MediaType and Size are only filled in if we happened to have to look them up anyhow (a source with a digest does not need a lookup, so we do not do one)
func serverSideCopyManifest(ctx context.Context, srcRef, dstRef Reference) (ociregistry.Descriptor, bool) {
	if srcRef.Host != dstRef.Host || srcRef.Repository == dstRef.Repository {
		return ociregistry.Descriptor{}, false
	}

	// this is checked first so that a registry (or pair of namespaces) we already know does not work never costs us even a lookup
	host := srcRef.Host
	pairKey := host + "|" + repoNamespace(srcRef.Repository) + "|" + repoNamespace(dstRef.Repository)
	if _, disabled := serverSideCopyDisabled.Load(host); disabled {
		return ociregistry.Descriptor{}, false
	}
	if _, disabled := serverSideCopyDisabled.Load(pairKey); disabled {
		return ociregistry.Descriptor{}, false
	}

	// we always ask by digest, so if we were not given one, we need to find it (and a source that does not exist is a good reason to let the client side code produce the error)
	desc := ociregistry.Descriptor{Digest: srcRef.Digest}
	if srcRef.Digest == "" {
		r, err := Lookup(ctx, srcRef, &LookupOptions{Head: true})
		if err != nil || r == nil {
			return ociregistry.Descriptor{}, false
		}
		desc = r.Descriptor()
		r.Close()
		srcRef.Tag, srcRef.Digest = "", desc.Digest
	}
	if dstRef.Digest != "" && dstRef.Digest != srcRef.Digest {
		// a digest mismatch is an error, but the client side code is better equipped to report it
		return ociregistry.Descriptor{}, false
	}

	// if the destination already has this exact manifest (at this tag, if we were given one), there's nothing to do (the endpoint is not a cheap no-op: it redoes the whole push, including checking every child), see also the same assumption in "EnsureManifest" that this means child objects exist as well
	headRef := dstRef
	if headRef.Tag != "" {
		// a lookup with both prefers the digest, which would not tell us anything about the tag
		headRef.Digest = ""
	} else {
		headRef.Digest = srcRef.Digest
	}
	if r, err := Lookup(ctx, headRef, &LookupOptions{Head: true}); err == nil && r != nil {
		head := r.Descriptor()
		r.Close()
		if head.Digest == srcRef.Digest {
			return head, true
		}
	}

	if !requestServerSideCopy(ctx, srcRef, dstRef) {
		return ociregistry.Descriptor{}, false
	}
	return desc, true
}

// the actual request for [serverSideCopyManifest] (srcRef must have a Digest, and every precondition has been checked), which also records anything we learn about what the registry does not support
func requestServerSideCopy(ctx context.Context, srcRef, dstRef Reference) bool {
	host := srcRef.Host
	pairKey := host + "|" + repoNamespace(srcRef.Repository) + "|" + repoNamespace(dstRef.Repository)

	// making sure "Client" has run for this host is what populates "transportCache"
	if _, err := Client(host, nil); err != nil {
		return false
	}
	rt, ok := transportCache.Load(host)
	if !ok {
		return false
	}

	connectHost, insecure := registryConnectHost(host)
	scheme := "https"
	if insecure {
		scheme = "http"
	}

	query := url.Values{
		"from":      {srcRef.Repository},
		"reference": {string(srcRef.Digest)}, // by digest so there's no implicit tag (and so we know exactly what we're asking for)
	}
	if dstRef.Tag != "" {
		query.Set("tag", dstRef.Tag)
	}
	u := url.URL{
		Scheme:   scheme,
		Host:     connectHost,
		Path:     "/v2/" + dstRef.Repository + "/_docker/copy/image",
		RawQuery: query.Encode(),
	}

	// the server requires push on the destination and pull on the source (the same as it does for a blob mount)
	ctx = ociauth.ContextWithRequestInfo(ctx, ociauth.RequestInfo{
		RequiredScope: ociauth.NewScope(
			ociauth.ResourceScope{ResourceType: ociauth.TypeRepository, Resource: dstRef.Repository, Action: ociauth.ActionPush},
			ociauth.ResourceScope{ResourceType: ociauth.TypeRepository, Resource: dstRef.Repository, Action: ociauth.ActionPull},
			ociauth.ResourceScope{ResourceType: ociauth.TypeRepository, Resource: srcRef.Repository, Action: ociauth.ActionPull},
		),
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), http.NoBody)
	if err != nil {
		return false
	}
	resp, err := (&http.Client{Transport: rt.(http.RoundTripper)}).Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	switch {
	case resp.StatusCode == http.StatusCreated:
		// the digest we get back is the one the server actually copied, so it had better be the one we asked for
		return resp.Header.Get("Docker-Content-Digest") == string(srcRef.Digest)

	case resp.StatusCode == http.StatusMethodNotAllowed,
		resp.StatusCode == http.StatusNotFound && !strings.HasPrefix(resp.Header.Get("Content-Type"), "application/json"):
		// a non-JSON 404 (like the plain text "404 page not found") means the endpoint does not exist at all, so this registry will never support this and we should stop asking it
		serverSideCopyDisabled.Store(host, true)

	case resp.StatusCode == http.StatusBadRequest && responseHasErrorCode(body, "MANIFEST_BLOB_UNKNOWN"):
		// the endpoint exists, but it did not mount anything (it falls back to a normal manifest push with no mounting if the feature is not enabled for either namespace), so stop asking about this specific pair of namespaces
		serverSideCopyDisabled.Store(pairKey, true)
	}

	// anything else (401, 403, 5xx, a JSON 404 for an unknown manifest, etc) might be specific to this one manifest and/or temporary, so we do not remember it, we just fall back
	return false
}

// whether body is an OCI distribution error response containing the given error code
func responseHasErrorCode(body []byte, code string) bool {
	var errs struct {
		Errors []struct {
			Code string `json:"code"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(body, &errs); err != nil {
		return false
	}
	for _, e := range errs.Errors {
		if e.Code == code {
			return true
		}
	}
	return false
}
