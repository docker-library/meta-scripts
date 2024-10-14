package registry

import (
	"net/http"
	"time"

	"golang.org/x/time/rate"
)

var (
	registryRateLimiters = map[string]*rate.Limiter{
		dockerHubCanonical: rate.NewLimiter(200/rate.Limit((1*time.Minute).Seconds()), 200), // stick to at most 200/min in registry/Hub requests (and allow an immediate burst of 200)
	}
)

// an implementation of [net/http.RoundTripper] that transparently adds a total requests rate limit and 429-retrying behavior
type rateLimitedRetryingRoundTripper struct {
	roundTripper http.RoundTripper
	limiter      *rate.Limiter
}

func (d *rateLimitedRetryingRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	var (
		// cap request retries at once per second
		requestRetryLimiter = rate.NewLimiter(rate.Every(time.Second), 1)

		// if we see 3x (503 or 502 or 500) during retry, we should bail
		maxTry50X = 3

		ctx = req.Context()
	)
	for {
		if err := requestRetryLimiter.Wait(ctx); err != nil {
			return nil, err
		}
		if err := d.limiter.Wait(ctx); err != nil {
			return nil, err
		}

		// in theory, this RoundTripper we're invoking should close req.Body (per the RoundTripper contract), so we shouldn't have to 🤞
		res, err := d.roundTripper.RoundTrip(req)
		if err != nil {
			return nil, err
		}

		doRetry := false

		if res.StatusCode == 429 {
			// just eat all available tokens and starve out the rate limiter (any 429 means we need to slow down, so our whole "bucket" is shot)
			for i := d.limiter.Tokens(); i > 0; i-- {
				_ = d.limiter.Allow()
			}
			doRetry = true // TODO maximum number of retries? (perhaps a deadline instead?  req.WithContext to inject a deadline?  👀)
		}

		// certain status codes should result in a few auto-retries (especially with the automatic retry delay this injects), but up to a limit so we don't contribute to the "thundering herd" too much in a serious outage
		if (res.StatusCode == 503 || res.StatusCode == 502 || res.StatusCode == 500) && maxTry50X > 1 {
			maxTry50X--
			doRetry = true
			// no need to eat up the rate limiter tokens as we do for 429 because this is not a rate limiting error (and we have the "requestRetryLimiter" that separately limits our retries of *this* request)
		}

		if doRetry {
			// satisfy the big scary warnings on https://pkg.go.dev/net/http#RoundTripper and https://pkg.go.dev/net/http#Client.Do about the downsides of failing to Close the response body
			if err := res.Body.Close(); err != nil {
				return nil, err
			}

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

			// TODO some way to notify upwards that we retried?
			// TODO implement more backoff logic than just one retry per second + docker hub rate limit (+ limited 50X retry)?
			continue
		}

		return res, nil
	}
}
