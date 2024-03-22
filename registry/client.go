package registry

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"

	"cuelabs.dev/go/oci/ociregistry"
	"cuelabs.dev/go/oci/ociregistry/ociauth"
	"cuelabs.dev/go/oci/ociregistry/ociclient"
)

// returns an [ociregistry.Interface] that automatically implements an in-memory cache (see [RegistryCache]) *and* transparent rate limiting + retry (see [registryRateLimiters]/[rateLimitedRetryingDoer]) / `DOCKERHUB_PUBLIC_PROXY` support for Docker Hub (cached such that multiple calls for the same registry transparently return the same client object / in-memory registry cache)
func Client(host string, opts *ociclient.Options) (ociregistry.Interface, error) {
	f, _ := clientCache.LoadOrStore(host, sync.OnceValues(func() (ociregistry.Interface, error) {
		authConfig, err := authConfigFunc()
		if err != nil {
			return nil, err
		}

		var clientOptions ociclient.Options
		if opts != nil {
			clientOptions = *opts
		}
		if clientOptions.Transport == nil {
			clientOptions.Transport = http.DefaultTransport
		}

		// if we have a rate limiter configured for this registry, shim it in
		if limiter, ok := registryRateLimiters[host]; ok {
			clientOptions.Transport = &rateLimitedRetryingRoundTripper{
				roundTripper: clientOptions.Transport,
				limiter:      limiter,
			}
		}

		// install the "authorization" wrapper/shim
		clientOptions.Transport = ociauth.NewStdTransport(ociauth.StdTransportParams{
			Config:    authConfig,
			Transport: clientOptions.Transport,
		})

		connectHost := host
		if host == dockerHubCanonical {
			connectHost = dockerHubConnect
		} else if host == "localhost" || strings.HasPrefix(host, "localhost:") {
			// assume localhost means HTTP
			clientOptions.Insecure = true
			// TODO some way for callers to specify that their "localhost" *does* require TLS (maybe only do this if `opts == nil`, but then users cannot supply *any* options and still get help setting Insecure for localhost 🤔 -- at least this is a more narrow use case than the opposite of not having a way to have non-localhost insecure registries)
		}

		hostOptions := clientOptions // make a copy, since "ociclient.New" mutates it (such that sharing the object afterwards probably isn't the best idea -- they'll have the same DebugID if so, which isn't ideal)
		client, err := ociclient.New(connectHost, &hostOptions)
		if err != nil {
			return nil, err
		}

		if host == dockerHubCanonical {
			var proxyHost string
			proxyOptions := clientOptions
			if proxy := os.Getenv("DOCKERHUB_PUBLIC_PROXY"); proxy != "" {
				proxyUrl, err := url.Parse(proxy)
				if err != nil {
					return nil, fmt.Errorf("error parsing DOCKERHUB_PUBLIC_PROXY: %w", err)
				}
				if proxyUrl.Host == "" {
					return nil, fmt.Errorf("DOCKERHUB_PUBLIC_PROXY was set, but has no host")
				}
				proxyHost = proxyUrl.Host
				switch proxyUrl.Scheme {
				case "", "https":
					proxyOptions.Insecure = false
				case "http":
					proxyOptions.Insecure = true
				default:
					return nil, fmt.Errorf("unknown DOCKERHUB_PUBLIC_PROXY scheme: %q", proxyUrl.Scheme)
				}
				switch proxyUrl.Path {
				case "", "/":
					// do nothing, this is fine
				default:
					return nil, fmt.Errorf("unsupported DOCKERHUB_PUBLIC_PROXY (with path)")
				}
				// TODO complain about other URL bits (unsupported by "ociclient" except via custom "RoundTripper")
			} else if proxy := os.Getenv("DOCKERHUB_PUBLIC_PROXY_HOST"); proxy != "" {
				proxyHost = proxy
			}
			if proxyHost != "" {
				proxyClient, err := ociclient.New(proxyHost, &proxyOptions)
				if err != nil {
					return nil, err
				}

				// see https://github.com/cue-labs/oci/blob/8cd71b4d542c55ae2ab515d4a0408ffafe41b549/ociregistry/ocifilter/readonly.go#L22 for the inspiration of this amazing hack (DOCKERHUB_PUBLIC_PROXY is designed for *only* reading content, but is a "pure" mirror in that even a 404 from the proxy is considered authoritative / accurate)
				// TODO *technically*, a non-404/429 error from the proxy should probably result in a fallback to Docker Hub, but this should be fine for now
				type deeper struct {
					// "If you're writing your own implementation of Funcs, you'll need to embed a *Funcs value to get an implementation of the private method. This means that it will be possible to add members to Interface in the future without breaking compatibility."
					*ociregistry.Funcs
				}
				client = struct {
					// see also https://pkg.go.dev/cuelabs.dev/go/oci/ociregistry#Interface
					ociregistry.Reader
					ociregistry.Lister
					ociregistry.Writer
					ociregistry.Deleter
					deeper // "One level deeper so the Reader and Lister values take precedence, following Go's shallower-method-wins rules."
				}{
					Reader:  proxyClient,
					Lister:  proxyClient,
					Writer:  client,
					Deleter: client,
				}
			}
		}

		// make sure this registry gets a dedicated in-memory cache (so we never look up the same repo@digest or repo:tag twice for the lifetime of our program)
		client = RegistryCache(client)
		// TODO some way for callers of this to *not* get a RegistryCache instance? (or to provide options to the one we create -- see TODO on RegistryCache constructor function)

		return client, nil
	}))
	return f.(func() (ociregistry.Interface, error))()
}

type dockerAuthConfigWrapper struct {
	ociauth.Config
}

// for Docker Hub, display should be docker.io, auth should be index.docker.io, and requests should be registry-1.docker.io (thanks to a lot of mostly uninteresting historical facts), so this hacks up ociauth to handle that case more cleanly by wrapping the actual auth config (see "dockerHubHosts" map)
func (c dockerAuthConfigWrapper) EntryForRegistry(host string) (ociauth.ConfigEntry, error) {
	var zero ociauth.ConfigEntry // "EntryForRegistry" doesn't return an error on a miss - it just returns an empty object (so we create this to have something to trivially compare against for our fallback)
	if entry, err := c.Config.EntryForRegistry(host); err == nil && entry != zero {
		return entry, err
	} else if dockerHubHosts[host] {
		// TODO this will iterate in a random order -- maybe that's fine, but maybe we want something more stable? (the new "SortedKeys" iterator that we might get in go1.23? I guess that was rejected, so "slices.Sorted(maps.Keys)")
		for dockerHubHost := range dockerHubHosts {
			if dockerHubHost == "" {
				continue
			}
			if entry, err := c.Config.EntryForRegistry(dockerHubHost); err == nil && entry != zero {
				return entry, err
			}
		}
		return entry, err
	} else {
		return entry, err
	}
}

var (
	authConfigFunc = sync.OnceValues(func() (ociauth.Config, error) {
		config, err := ociauth.Load(nil)
		if err != nil {
			return nil, fmt.Errorf("cannot load auth configuration: %w", err)
		}
		return dockerAuthConfigWrapper{config}, nil
	})
	clientCache = sync.Map{} // "(normalized) host" => OnceValues() => ociregistry.Interface, error
)
