package registry

import (
	"net/http"
	"time"

	"golang.org/x/time/rate"
)

var (
	registryRateLimiters = map[string]*rate.Limiter{
		dockerHubCanonical: rate.NewLimiter(100/rate.Limit((1*time.Minute).Seconds()), 100), // stick to at most 100/min in registry/Hub requests (and allow an immediate burst of 100)
	}
)

// an implementation of [net/http.RoundTripper] that transparently adds a total requests rate limit and 429-retrying behavior
type rateLimitedRetryingRoundTripper struct {
	roundTripper http.RoundTripper
	limiter      *rate.Limiter
}

func (d *rateLimitedRetryingRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	requestRetryLimiter := rate.NewLimiter(rate.Every(time.Second), 1) // cap request retries at once per second
	firstTry := true
	ctx := req.Context()
	for {
		if err := requestRetryLimiter.Wait(ctx); err != nil {
			return nil, err
		}
		if err := d.limiter.Wait(ctx); err != nil {
			return nil, err
		}

		if !firstTry {
			// https://pkg.go.dev/net/http#RoundTripper
			// "RoundTrip should not modify the request, except for consuming and closing the Request's Body."
			if req.Body != nil {
				req.Body.Close()
			}
			req = req.Clone(ctx)
			if req.GetBody != nil {
				var err error
				req.Body, err = req.GetBody()
				if err != nil {
					return nil, err
				}
			}
		}
		firstTry = false

		// in theory, this RoundTripper we're invoking should close req.Body (per the RoundTripper contract), so we shouldn't have to 🤞
		res, err := d.roundTripper.RoundTrip(req)
		if err != nil {
			return nil, err
		}

		// TODO 503 should probably result in at least one or two auto-retries (especially with the automatic retry delay this injects)
		if res.StatusCode == 429 {
			// satisfy the big scary warnings on https://pkg.go.dev/net/http#RoundTripper and https://pkg.go.dev/net/http#Client.Do about the downsides of failing to Close the response body
			if err := res.Body.Close(); err != nil {
				return nil, err
			}

			// just eat all available tokens and starve out the rate limiter (any 429 means we need to slow down, so our whole "bucket" is shot)
			for i := d.limiter.Tokens(); i > 0; i-- {
				_ = d.limiter.Allow()
			}

			// TODO some way to notify upwards that we retried?
			// TODO maximum number of retries? (perhaps a deadline instead?  req.WithContext to inject a deadline?  👀)
			// TODO implement more backoff logic than just one retry per second + docker hub rate limit?
			continue
		}

		return res, nil
	}
}
