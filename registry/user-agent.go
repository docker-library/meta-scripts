package registry

// https://github.com/docker-library/meta-scripts/issues/111
// https://github.com/cue-labs/oci/issues/37

import (
	"fmt"
	"maps"
	"net/http"
)

// an implementation of [net/http.RoundTripper] that transparently injects User-Agent (as a wrapper around another [net/http.RoundTripper])
type userAgentRoundTripper struct {
	roundTripper http.RoundTripper
	userAgent    string
}

func (d *userAgentRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	// if d is nil or if d.roundTripper is nil, we'll just let the runtime panic because those are both 100% coding errors in the consuming code

	if d.userAgent == "" {
		// arguably we could `panic` here too since this is *also* a coding error, but it'd be pretty reasonable to source this from an environment variable so `panic` is perhaps a bit user-hostile
		return nil, fmt.Errorf("missing userAgent in userAgentRoundTripper! (request %s)", req.URL)
	}

	// https://github.com/cue-lang/cue/blob/0a43336cccf3b6fc632e976912d74fb2c9670557/internal/cueversion/transport.go#L27-L34
	reqClone := *req
	reqClone.Header = maps.Clone(reqClone.Header)
	reqClone.Header.Set("User-Agent", d.userAgent)
	return d.roundTripper.RoundTrip(&reqClone)
}
